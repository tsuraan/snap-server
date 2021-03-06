{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.FastLogger
( Logger
, timestampedLogEntry
, combinedLogEntry
, newLogger
, logMsg
, stopLogger
) where


------------------------------------------------------------------------------
import           Blaze.ByteString.Builder
import           Blaze.ByteString.Builder.Char.Utf8
import           Control.Concurrent
import           Control.Exception
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as L
import           Data.ByteString.Internal (c2w)
import           Data.Int
import           Data.IORef
import           Data.Monoid
import           Prelude hiding (catch)
import           System.IO

import           Snap.Internal.Http.Server.Date


------------------------------------------------------------------------------
-- | Holds the state for a logger.
data Logger = Logger
    { _queuedMessages :: !(IORef Builder)
    , _dataWaiting    :: !(MVar ())
    , _loggerPath     :: !(FilePath)
    , _loggingThread  :: !(MVar ThreadId) }


------------------------------------------------------------------------------
-- | Creates a new logger, logging to the given file. If the file argument is
-- \"-\", then log to stdout; if it's \"stderr\" then we log to stderr,
-- otherwise we log to a regular file in append mode. The file is closed and
-- re-opened every 15 minutes to facilitate external log rotation.
newLogger :: FilePath -> IO Logger
newLogger fp = do
    q  <- newIORef mempty
    dw <- newEmptyMVar
    th <- newEmptyMVar

    let lg = Logger q dw fp th

    tid <- forkIO $ loggingThread lg
    putMVar th tid

    return lg


------------------------------------------------------------------------------
-- | Prepares a log message with the time prepended.
timestampedLogEntry :: ByteString -> IO ByteString
timestampedLogEntry msg = do
    timeStr <- getLogDateString

    return $! toByteString
           $! mconcat [ fromWord8 $ c2w '['
                      , fromByteString timeStr
                      , fromByteString "] "
                      , fromByteString msg ]


------------------------------------------------------------------------------
-- | Prepares a log message in \"combined\" format.
combinedLogEntry :: ByteString        -- ^ remote host
                 -> Maybe ByteString  -- ^ remote user
                 -> ByteString        -- ^ request line (up to you to ensure
                                      --   there are no quotes in here)
                 -> Int               -- ^ status code
                 -> Maybe Int64       -- ^ num bytes sent
                 -> Maybe ByteString  -- ^ referer (up to you to ensure
                                      --   there are no quotes in here)
                 -> ByteString        -- ^ user agent (up to you to ensure
                                      --   there are no quotes in here)
                 -> IO ByteString
combinedLogEntry !host !mbUser !req !status !mbNumBytes !mbReferer !ua = do
    timeStr <- getLogDateString

    let !l = [ fromByteString host
             , fromByteString " - "
             , user
             , fromByteString " ["
             , fromByteString timeStr
             , fromByteString "] \""
             , fromByteString req
             , fromByteString "\" "
             , fromShow status
             , space
             , numBytes
             , space
             , referer
             , fromByteString " \""
             , fromByteString ua
             , quote ]

    let !output = toByteString $ mconcat l

    return $! output

  where
    dash     = fromWord8 $ c2w '-'
    quote    = fromWord8 $ c2w '\"'
    space    = fromWord8 $ c2w ' '
    user     = maybe dash fromByteString mbUser
    numBytes = maybe dash fromShow mbNumBytes
    referer  = maybe dash
                     (\s -> mconcat [ quote
                                    , fromByteString s
                                    , quote ])
                     mbReferer


------------------------------------------------------------------------------
-- | Sends out a log message verbatim with a newline appended. Note:
-- if you want a fancy log message you'll have to format it yourself
-- (or use 'combinedLogEntry').
logMsg :: Logger -> ByteString -> IO ()
logMsg !lg !s = do
    let !s' = fromByteString s `mappend` (fromWord8 $ c2w '\n')
    atomicModifyIORef (_queuedMessages lg) $ \d -> (d `mappend` s',())
    tryPutMVar (_dataWaiting lg) () >> return ()


------------------------------------------------------------------------------
loggingThread :: Logger -> IO ()
loggingThread (Logger queue notifier filePath _) = do
    initialize >>= go

  where
    openIt =
        if filePath == "-"
          then return stdout
          else if filePath == "stderr"
                 then return stderr
                 else openFile filePath AppendMode `catch`
                      \(e::SomeException) -> do
                          hPutStrLn stderr $ "can't open log file " ++ filePath
                          hPutStrLn stderr $ "exception: " ++ show e
                          hPutStrLn stderr $ "logging to stderr instead."
                          return stderr

    closeIt h = if h == stdout || h == stderr
                  then return ()
                  else hClose h

    go (href, lastOpened) =
        (loop (href, lastOpened))
          `catches`
          [ Handler $ \(_::AsyncException) -> killit (href, lastOpened)
          , Handler $ \(e::SomeException)  -> do
                hPutStrLn stderr $ "logger got exception: " ++ Prelude.show e
                threadDelay 20000000
                go (href, lastOpened) ]


    initialize = do
        lh   <- openIt
        href <- newIORef lh
        t    <- getCurrentDateTime
        tref <- newIORef t
        return (href, tref)


    killit (href, lastOpened) = do
        flushIt (href, lastOpened)
        h <- readIORef href
        closeIt h


    flushIt (!href, !lastOpened) = do
        dl <- atomicModifyIORef queue $ \x -> (mempty,x)

        let !msgs = toLazyByteString dl
        h <- readIORef href
        (do L.hPut h msgs
            hFlush h) `catch` \(e::SomeException) -> do
                hPutStrLn stderr $ "got exception writing to log " ++
                                   filePath ++ ": " ++ show e
                hPutStrLn stderr $ "writing log entries to stderr."
                L.hPut stderr msgs
                hFlush stderr

        -- close the file every 15 minutes (for log rotation)
        t   <- getCurrentDateTime
        old <- readIORef lastOpened

        if t-old > 900
          then do
              closeIt h
              openIt >>= writeIORef href
              writeIORef lastOpened t
          else return ()


    loop !d = do
        -- wait on the notification mvar
        _ <- takeMVar notifier

        -- grab the queued messages and write them out
        flushIt d

        -- at least five seconds between log dumps
        threadDelay 5000000
        loop d


------------------------------------------------------------------------------
-- | Kills a logger thread, causing any unwritten contents to be
-- flushed out to disk
stopLogger :: Logger -> IO ()
stopLogger lg = withMVar (_loggingThread lg) killThread
