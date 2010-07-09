{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{-|

The Snap HTTP server is a high performance, epoll-enabled, iteratee-based web
server library written in Haskell. Together with the @snap-core@ library upon
which it depends, it provides a clean and efficient Haskell programming
interface to the HTTP protocol.

-}


module Snap.Http.Server
  ( Config(..)
  , defaultConfig
  , commandLineConfig
  , simpleHttpServe
  , internalError
  , httpServe
  , quickHttpServe
  , snapServerVersion
  ) where

import           Control.Exception (SomeException)
import           Control.Monad
import           Control.Monad.CatchIO
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as U
import           Data.ByteString (ByteString)
import           Data.Char
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Prelude hiding (catch)
import qualified Snap.Internal.Http.Server as Int
import           Snap.Iteratee ((>.), enumBS)
import           Snap.Types
import           Snap.Util.GZip
import           System.Console.GetOpt
import           System.Environment hiding (getEnv)
#ifndef PORTABLE
import           System.Posix.Env
#endif
import           System.Exit
import           System.IO


------------------------------------------------------------------------------
-- | A record type which represents partial configurations (for 'httpServe')
-- by wrapping all of its fields in a 'Maybe'. Values of this type are usually
-- constructed via its 'Monoid' instance by doing something like:
--
-- > mempty { port = Just 9000}
--
-- Any fields which are unspecified in the 'Config' passed to 'httpServe' (and
-- this is the norm) are filled in with default values from 'defaultConfig'.
data Config = Config
    { hostname     :: Maybe ByteString
      -- ^ The name of the server
    , address      :: Maybe ByteString
      -- ^ The local interface to bind to
    , port         :: Maybe Int
      -- ^ The local port to bind to
    , accessLog    :: Maybe (Maybe FilePath)
      -- ^ The path to the access log
    , errorLog     :: Maybe (Maybe FilePath)
      -- ^ The path to the error log
    , locale       :: Maybe String
      -- ^ The locale to use
    , compression  :: Maybe Bool
      -- ^ Whether to use compression
    , verbose      :: Maybe Bool
      -- ^ Whether to write server status updates to stderr
    , errorHandler :: Maybe (SomeException -> Snap ())
      -- ^ A Snap action to handle 500 errors
    }


------------------------------------------------------------------------------
instance Show (Config) where
    show c = "Config {" ++ concat (intersperse ", " $ filter (/="") $ map ($c)
        [ showM "hostname" . hostname
        , showM "address" . address
        , showM "port" . port
        , showM "accessLog" . accessLog
        , showM "errorLog" . errorLog
        , showM "locale" . locale
        , showM "compression" . compression
        , showM "verbose" . verbose
        , showM "errorHandler" . fmap (const ()) . errorHandler
        ]) ++ "}"
      where
        showM s = maybe "" ((++) (s ++ " = ") . show)


------------------------------------------------------------------------------
instance Monoid (Config) where
    mempty = Config
        { hostname     = Nothing
        , address      = Nothing
        , port         = Nothing
        , accessLog    = Nothing
        , errorLog     = Nothing
        , locale       = Nothing
        , compression  = Nothing
        , verbose      = Nothing
        , errorHandler = Nothing
        }

    a `mappend` b = Config
        { hostname     = (hostname     b) `mplus` (hostname     a)
        , address      = (address      b) `mplus` (address      a)
        , port         = (port         b) `mplus` (port         a)
        , accessLog    = (accessLog    b) `mplus` (accessLog    a)
        , errorLog     = (errorLog     b) `mplus` (errorLog     a)
        , locale       = (locale       b) `mplus` (locale       a)
        , compression  = (compression  b) `mplus` (compression  a)
        , verbose      = (verbose      b) `mplus` (verbose      a)
        , errorHandler = (errorHandler b) `mplus` (errorHandler a)
        }


------------------------------------------------------------------------------
-- | This function creates a simple plain text error page with the provided
-- content.  It sets the response status to 500, and short-circuits further
-- handling of the request
internalError :: (MonadSnap m) => ByteString -> m a
internalError msg =
    let rsp = setContentType "text/plain; charset=utf-8"
            . setContentLength (fromIntegral $ B.length msg)
            . setResponseStatus 500 "Internal Server Error"
            . modifyResponseBody (>. enumBS msg)
            $ emptyResponse
    in finishWith rsp


------------------------------------------------------------------------------
-- | These are the default values for all the fields in 'Config'.
--
-- > hostname     = "localhost"
-- > address      = "0.0.0.0"
-- > port         = 8000
-- > accessLog    = "log/access.log"
-- > errorLog     = "log/error.log"
-- > locale       = "en_US"
-- > compression  = True
-- > verbose      = True
-- > errorHandler = prints the error message
--
defaultConfig :: Config
defaultConfig = Config
    { hostname     = Just "localhost"
    , address      = Just "0.0.0.0"
    , port         = Just 8000
    , accessLog    = Just $ Just "log/access.log"
    , errorLog     = Just $ Just "log/error.log"
    , locale       = Just "en_US"
    , compression  = Just True
    , verbose      = Just True
    , errorHandler = Just $ \e -> do
        internalError $ "A web handler threw an exception. Details:\n"
            `mappend` (U.fromString $ show e)
    }


------------------------------------------------------------------------------
-- | Completes a partial 'Config' by filling in the unspecified values with
-- the default values from 'defaultConfig'.
completeConfig :: Config -> Config
completeConfig = mappend defaultConfig


------------------------------------------------------------------------------
-- | A description of the command-line options accepted by
-- 'commandLineConfig'.
--
-- The 'Config' parameter is just for specifying any default values which are
-- to override those in 'defaultConfig'. This is so the usage message can
-- accurately inform the user what the default values for the options are. In
-- most cases, you will probably just end up passing 'mempty' for this
-- parameter.
--
-- The return type is a list of options describing a @'Maybe' 'Config@ as
-- opposed to a @'Config'@, because if the @--help@ option is given, the set
-- of command-line options no longer describe a config, but an action
-- (printing out the usage message).
options :: Config -> [OptDescr (Maybe Config)]
options defaults =
    [ Option [] ["hostname"]
             (ReqArg (\h -> Just $ mempty {hostname = Just $ bs h}) "NAME")
             $ "local hostname" ++ default_ hostname
    , Option ['b'] ["address"]
             (ReqArg (\a -> Just $ mempty {address = Just $ bs a}) "ADDRESS")
             $ "address to bind to" ++ default_ address
    , Option ['p'] ["port"]
             (ReqArg (\p -> Just $ mempty {port = Just $ read p}) "PORT")
             $ "port to listen on" ++ default_ port
    , Option [] ["access-log"]
             (ReqArg (\l -> Just $ mempty {accessLog = Just $ Just l}) "PATH")
             $ "access log" ++ (default_ $ join . accessLog)
    , Option [] ["error-log"]
             (ReqArg (\l -> Just $ mempty {errorLog = Just $ Just l}) "PATH")
             $ "error log" ++ (default_ $ join . errorLog)
    , Option [] ["no-access-log"]
             (NoArg $ Just mempty {accessLog = Just Nothing})
             $ "don't have an access log"
    , Option [] ["no-error-log"]
             (NoArg $ Just mempty {errorLog = Just Nothing})
             $ "don't have an error log"
    , Option ['c'] ["compression"]
             (NoArg $ Just $ mempty {compression = Just True})
             $ "use gzip compression on responses"
    , Option [] ["no-compression"]
             (NoArg $ Just $ mempty {compression = Just False})
             $ "serve responses uncompressed"
    , Option ['v'] ["verbose"]
             (NoArg $ Just $ mempty {verbose = Just True})
             $ "print server status updates to stderr"
    , Option ['q'] ["quiet"]
             (NoArg $ Just $ mempty {verbose = Just False})
             $ "do not print anything to stderr"
    , Option ['h'] ["help"]
             (NoArg Nothing)
             $ "display this help and exit"
    ]
  where
    bs         = U.fromString
    conf       = completeConfig defaults
    default_ f = maybe "" ((", default " ++) . show) $ f conf


------------------------------------------------------------------------------
-- | This returns a 'Config' gotten from parsing the options specified on the
-- command-line.
--
-- The 'Config' parameter is just for specifying any default values which are
-- to override those in 'defaultConfig'. This is so the usage message can
-- accurately inform the user what the default values for the options are. In
-- most cases, you will probably just end up passing 'mempty' for this
-- parameter.
--
-- On Unix systems, the locale is read from the @LANG@ environment variable.
commandLineConfig :: Config -> IO Config
commandLineConfig defaults = do
    args <- getArgs
    prog <- getProgName

    result <- either (usage prog) return $ case getOpt Permute opts args of
        (f, _, []  ) -> maybe (Left []) Right $ fmap mconcat $ sequence f
        (_, _, errs) -> Left errs

#ifndef PORTABLE
    lang <- getEnv "LANG"
    return $ mconcat [defaults, result, mempty {locale = fmap untilUTF8 lang}]
#else
    return $ mconcat [defaults, result]
#endif

  where
    opts = options defaults
    usage prog errs = do
        let hdr = "Usage:\n  " ++ prog ++ " [OPTION...]\n\nOptions:"
        let msg = concat errs ++ usageInfo hdr opts
        hPutStrLn stderr msg
        exitFailure
    untilUTF8 = takeWhile $ \c -> c == '_' || isAlpha c


------------------------------------------------------------------------------
-- | A short string describing the Snap server version
snapServerVersion :: ByteString
snapServerVersion = Int.snapServerVersion


------------------------------------------------------------------------------
-- | Starts serving HTTP requests using the given handler. Any settings it
-- requires are passed directly to it.
simpleHttpServe :: ByteString     -- ^ bind address, or \"*\" for all
                -> Int            -- ^ port to bind to
                -> ByteString     -- ^ local hostname (server name)
                -> Maybe FilePath -- ^ path to the (optional) access log
                -> Maybe FilePath -- ^ path to the (optional) error log
                -> Snap ()        -- ^ handler procedure
                -> IO ()

simpleHttpServe address' port' hostname' alog elog handler =
    Int.httpServe address' port' hostname' alog elog handler'
  where
    handler' = runSnap handler


------------------------------------------------------------------------------
-- | Starts serving HTTP requests using the given handler, with settings from
-- the 'Config' passed in. This function never returns; to shut down the HTTP
-- server, kill the controlling thread.
httpServe :: Config
          -- ^ Any configuration options which override the defaults
          -> Snap ()
          -- ^ The application to be served
          -> IO ()
httpServe config handler = do
    setUnicodeLocale $ conf locale
    output $ "Listening on " ++ (U.toString $ conf address) ++ ":" ++
        (show $ conf port)
    try $ serve $ compress $ catch500 handler :: IO (Either SomeException ())
    output " shutting down.."
  where
    conf g = fromJust $ g $ completeConfig config
    output = when (conf verbose) . hPutStrLn stderr
    serve  = simpleHttpServe (conf address)
                             (conf port)
                             (conf hostname)
                             (conf accessLog)
                             (conf errorLog)
    catch500 = flip catch $ conf errorHandler
    compress = if conf compression then withCompression else id


------------------------------------------------------------------------------
-- | Starts serving HTTP using the given handler. The configuration is read
-- from the options given on the command-line, as returned by
-- 'commandLineConfig'.
quickHttpServe :: Snap ()
               -- ^ The application to be served
               -> IO ()
quickHttpServe m = commandLineConfig mempty >>= \c -> httpServe c m


------------------------------------------------------------------------------
-- | Given a string like \"en_US\", this sets the locale to \"en_US.utf8\".
-- This doesn't work on Windows.
setUnicodeLocale :: String -> IO ()
setUnicodeLocale lang = do
#ifndef PORTABLE
    mapM_ (\k -> setEnv k (lang ++ ".utf-8") True)
          [ "LANG"
          , "LC_CTYPE"
          , "LC_NUMERIC"
          , "LC_TIME"
          , "LC_COLLATE"
          , "LC_MONETARY"
          , "LC_MESSAGES"
          , "LC_PAPER"
          , "LC_NAME"
          , "LC_ADDRESS"
          , "LC_TELEPHONE"
          , "LC_MEASUREMENT"
          , "LC_IDENTIFICATION"
          , "LC_ALL" ]
#else
    return ()
#endif
