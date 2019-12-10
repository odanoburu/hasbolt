{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Database.Bolt.Connection
  ( BoltActionT
  , BoltError (..)
  , UnpackError (..)
  , at
  , run, runE
  , queryP, query
  , queryP', query'
  , queryP_, query_
  ) where

import           Database.Bolt.Connection.Pipe
import           Database.Bolt.Connection.Instances
import           Database.Bolt.Connection.Type
import           Database.Bolt.Value.Type
import           Database.Bolt.Record

import           Control.Exception             (throwIO)
import           Control.Monad                 (void)
import           Control.Monad.Trans           (MonadIO (..))
import           Control.Monad.Reader          (MonadReader (..), runReaderT)
import           Control.Monad.Except          (MonadError (..), runExceptT)
import           Data.Text                     (Text)
import           Data.Map.Strict               (Map, empty, fromList)

import           System.IO.Unsafe              (unsafeInterleaveIO)

-- |Runs BOLT action on selected pipe
runE :: MonadIO m => Pipe -> BoltActionT m a -> m (Either BoltError a)
runE pipe action = runExceptT (runReaderT (runBoltActionT action) pipe) 

-- |Runs BOLT action on selected pipe (with errors throw)
run :: MonadIO m => Pipe -> BoltActionT m a -> m a
run pipe action = do result <- runE pipe action
                     case result of
                       Right x -> pure x
                       Left r  -> liftIO $ throwIO r

-- |Runs Cypher query with parameters and returns list of obtained 'Record's. Lazy version
queryP :: MonadIO m => Text -> Map Text Value -> BoltActionT m [Record]
queryP = querySL False

-- |Runs Cypher query and returns list of obtained 'Record's. Lazy version
query :: MonadIO m => Text -> BoltActionT m [Record]
query cypher = queryP cypher empty

-- |Runs Cypher query with parameters and returns list of obtained 'Record's. Strict version
queryP' :: MonadIO m => Text -> Map Text Value -> BoltActionT m [Record]
queryP' = querySL True

-- |Runs Cypher query and returns list of obtained 'Record's. Strict version
query' :: MonadIO m => Text -> BoltActionT m [Record]
query' cypher = queryP' cypher empty

-- |Runs Cypher query with parameters and ignores response
queryP_ :: MonadIO m => Text -> Map Text Value -> BoltActionT m ()
queryP_ cypher params = do void $ sendRequest cypher params
                           ask >>= liftE . discardAll

-- |Runs Cypher query and ignores response
query_ :: MonadIO m => Text -> BoltActionT m ()
query_ cypher = queryP_ cypher empty

-- Helper functions

querySL :: MonadIO m => Bool -> Text -> Map Text Value -> BoltActionT m [Record]
querySL strict cypher params = do keys <- pullKeys cypher params
                                  pullRecords strict keys

pullKeys :: MonadIO m => Text -> Map Text Value -> BoltActionT m [Text]
pullKeys cypher params = do pipe <- ask
                            status <- sendRequest cypher params
                            liftE $ flush pipe RequestPullAll
                            mkKeys status
  where
    mkKeys :: MonadIO m => Response -> BoltActionT m [Text]
    mkKeys (ResponseSuccess response) = response `at` "fields" `catchError` \(RecordHasNoKey _) -> pure []
    mkKeys x                          = throwError $ ResponseError (mkFailure x)

pullRecords :: MonadIO m => Bool -> [Text] -> BoltActionT m [Record]
pullRecords strict keys = do pipe <- ask
                             resp <- liftE $ fetch pipe
                             cases resp
  where
    cases :: MonadIO m => Response -> BoltActionT m [Record]
    cases resp | isSuccess resp = pure []
               | isFailure resp = do ask >>= ackFailure
                                     throwError $ ResponseError (mkFailure resp)
               | otherwise      = parseRecord resp

    parseRecord :: MonadIO m => Response -> BoltActionT m [Record]
    parseRecord resp = do
        pipe <- ask
        let record = fromList . zip keys $ recsList resp
        let pull = run pipe (pullRecords strict keys)
        rest <- liftIO $ if strict then pull
                                   else unsafeInterleaveIO pull
        pure (record:rest)

-- |Sends request to database and makes an action
sendRequest :: MonadIO m => Text -> Map Text Value -> BoltActionT m Response
sendRequest cypher params =
  do pipe <- ask
     liftE $ do
         flush pipe $ RequestRun cypher params
         status <- fetch pipe
         if isSuccess status
           then pure status
           else do ackFailure pipe
                   throwError $ ResponseError (mkFailure status)
