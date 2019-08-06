module Database.Bolt.Connection
  ( BoltActionT
  , run
  , queryP, query
  , queryP', query'
  , queryP_, query_
  ) where

import           Database.Bolt.Connection.Pipe
import           Database.Bolt.Connection.Instances
import           Database.Bolt.Connection.Type
import           Database.Bolt.Value.Type
import           Database.Bolt.Record

import           Control.Monad                 (void)
import           Control.Monad.IO.Class        (MonadIO (..), liftIO)
import           Control.Monad.Reader          (ReaderT (..), ask, runReaderT)
import           Data.Text                     (Text)
import           Data.Map.Strict               (Map, empty)

import           System.IO.Unsafe              (unsafeInterleaveIO)

-- |Monad Transformer to do all BOLT actions in
type BoltActionT = ReaderT Pipe

-- |Runs BOLT action on selected pipe
run :: Pipe -> BoltActionT m a -> m a
run = flip runReaderT

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
queryP_ cypher params = do pipe <- ask
                           liftIO $ do
                             void $ sendRequest pipe cypher params
                             discardAll pipe
     
-- |Runs Cypher query and ignores response
query_ :: MonadIO m => Text -> BoltActionT m ()
query_ cypher = queryP_ cypher empty

-- Helper functions

querySL :: MonadIO m => Bool -> Text -> Map Text Value -> BoltActionT m [Record]
querySL strict cypher params = do pipe <- ask
                                  liftIO $ do
                                    keys <- pullKeys pipe cypher params
                                    pullRecords strict pipe keys

pullKeys :: Pipe -> Text -> Map Text Value -> IO [Text]
pullKeys pipe cypher params = do status <- sendRequest pipe cypher params
                                 flush pipe RequestPullAll
                                 mkKeys status

pullRecords :: Bool -> Pipe -> [Text] -> IO [Record]
pullRecords strict pipe keys = fetch pipe >>= cases
  where
    cases :: Response -> IO [Record]
    cases resp | isSuccess resp = pure []
               | isFailure resp = ackFailure pipe >> mkFailure resp
               | otherwise      = parseRecord resp

    parseRecord :: Response -> IO [Record]
    parseRecord resp = do
        let record = mkRecord keys resp
        let pull = pullRecords strict pipe keys
        rest <- if strict then pull
                          else unsafeInterleaveIO pull
        pure (record:rest)

-- |Sends request to database and makes an action
sendRequest :: Pipe -> Text -> Map Text Value -> IO Response
sendRequest pipe cypher params =
  do flush pipe $ RequestRun cypher params
     status <- fetch pipe
     if isSuccess status
       then pure status
       else do ackFailure pipe
               mkFailure status
