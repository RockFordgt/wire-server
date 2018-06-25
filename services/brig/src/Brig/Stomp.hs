{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Working with STOMP queues.
module Brig.Stomp
    ( Env(..)
    , mkEnv
    , Broker(..)
    , Queue(..)
    , Credentials(..)
    , enqueue
    , listen
    ) where

import BasePrelude hiding (throwIO, try, timeout)

import Control.Lens
import Control.Monad.Catch (MonadMask)
import Control.Retry hiding (retryPolicy)
import Data.Aeson                                     as Aeson
import Data.Conduit.Network.TLS
import Data.Text
import Data.Text.Encoding
import Network.Mom.Stompl.Client.Queue hiding (try)
import System.Logger.Class
import UnliftIO

import qualified Brig.Options                         as Opts
import qualified Codec.MIME.Type                      as MIME
import qualified Data.ByteString.Lazy                 as BL

data Env = Env
    { broker        :: Broker      -- ^ STOMP broker that we're using
    , internalQueue :: Queue       -- ^ Internal event queue used by brig
    }

data Broker = Broker
    { _host :: Text                -- ^ Broker URL
    , _port :: Int                 -- ^ Port
    , _auth :: Maybe Credentials   -- ^ Username and password
    , _tls  :: Bool                -- ^ Whether to use TLS
    }

data Queue = Queue
    { _queueName :: Text           -- ^ Queue identifier, used only for debugging
    , _queuePath :: Text           -- ^ Queue path on the broker side
    }

data Credentials = Credentials
    { user :: Text
    , pass :: Text
    } deriving (Eq, Show, Generic)

instance FromJSON Credentials

makeLenses ''Broker
makeLenses ''Queue

-- | Construct an 'Env' with some default settings.
mkEnv
    :: Opts.StompOpts    -- ^ Options that can be customized
    -> Credentials       -- ^ Credentials
    -> Env
mkEnv o cred =
    Env { broker = Broker
              { _host = Opts.host o
              , _port = Opts.port o
              , _auth = Just cred
              , _tls  = Opts.tls o }
        , internalQueue = Queue
              { _queueName = "InternalEventQueue"
              , _queuePath = Opts.internalQueue o }
        }

-- | Send a message to a STOMP queue.
--
-- In case of failure will try five more times. The timeout for each attempt
-- is 500ms.
enqueue :: (ToJSON a, MonadIO m) => Broker -> Queue -> a -> m ()
enqueue b q m =
    retrying retryPolicy retryPredicate (const enqueueAction) >>= either throwIO pure
  where
    retryPredicate _ res = pure (isLeft res)
    retryPolicy = limitRetries 5 <> exponentialBackoff 50000
    enqueueAction =
        liftIO $ try @_ @StomplException $
        stompTimeout "enqueue" 500000 $
        withConnection' b $ \conn ->
        withWriter conn (unpack (q^.queueName)) (unpack (q^.queuePath))
                   [OWithReceipt, OWaitReceipt] [] oconv $ \w ->
            writeQ w jsonType [] m
    -- Note [receipts]
    -- ~~~
    -- When we acknowledge a message in 'listen', we don't need to wait for
    -- a receipt because nothing bad will happen if our ACK doesn't go
    -- through; handlers of events coming via queues are supposed to be
    -- idempotent.
    --
    -- However, when we *send* a message, we definitely want a receipt (a
    -- confirmation that the broker received the message). This doesn't
    -- eliminate failure modes entirely – if we don't get a receipt we might
    -- think that a message has not been enqueued while it in fact has – but
    -- it's better than the opposite.

-- | Forever listen to messages from a STOMP queue and execute a callback
-- for each incoming message.
--
-- In case of connection failure or an exception, will retry indefinitely.
--
-- When 'listen' catches any kind of exception, it will reestablish the
-- connection and get a new message to process. Assuming that the broker is
-- configured properly, after failing on the same message several times the
-- message will go into the Dead Letter Queue where it can be analyzed
-- manually.
listen :: (FromJSON a, MonadLogger m, MonadMask m, MonadUnliftIO m)
       => Broker -> Queue -> (a -> m ()) -> m ()
listen b q callback =
    recoverAll retryPolicy (const listenAction)  
  where
    retryPolicy = constantDelay 1000000
    listenAction =
        withRunInIO $ \runInIO ->
        withConnection' b $ \conn ->
        withReader conn (unpack (q^.queueName)) (unpack (q^.queuePath))
                   [OMode ClientIndi] [] (iconv (q^.queueName)) $ \r ->
            forever $ do
                m <- stompTimeout "listen/readQ" 1000000 $ readQ r
                runInIO $ callback (msgContent m)
                stompTimeout "listen/ack" 1000000 $ ack conn m
    -- Note [exception handling]
    -- ~~~
    -- The callback might throw an exception, which will be caught by
    -- 'recoverAll'. This will kill and restart the connection, while we could
    -- in theory do better (just throw away the exception without killing
    -- the connection). However, this is supposed to be a very rare case
    -- and it would complicate the code so we don't care.

-------------------------------------------------------------------------------
-- Utilities

iconv :: FromJSON a => Text -> InBound a
iconv queue _ _ _ bs =
    case Aeson.eitherDecode (BL.fromStrict bs) of
        Right x -> pure x
        Left e  -> convertError $
            "Error when parsing message from STOMP queue " <> unpack queue <> ": " <> e

oconv :: ToJSON a => OutBound a
oconv = pure . BL.toStrict . Aeson.encode

jsonType :: MIME.Type
jsonType = MIME.Type (MIME.Application "json") []

-- | Set up a STOMP connection.
withConnection' :: Broker -> (Con -> IO a) -> IO a
withConnection' b =
    withConnection (unpack (b^.host)) (b^.port) config []
  where
    config =
        [ OAuth (unpack (user cred)) (unpack (pass cred)) | Just cred <- [b^.auth] ] ++
        [ OTLS (tlsClientConfig (b^.port) (encodeUtf8 (b^.host))) | b^.tls ] ++
        [ OTmo 1000 ]

-- | Like 'timeout', but throws an 'AppException' instead of returning a
-- 'Maybe'. Not very composable, but kinda convenient here.
stompTimeout :: String -> Int -> IO a -> IO a
stompTimeout location t act = timeout t act >>= \case
    Just x  -> pure x
    Nothing -> throwIO $ AppException $
        location <> ": STOMP request took more than " <> show t <> "mcs and has timed out"
