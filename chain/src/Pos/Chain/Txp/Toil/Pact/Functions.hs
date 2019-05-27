{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Pos.Chain.Txp.Toil.Pact.Functions where

import           Universum
import qualified Universum.Unsafe as Unsafe

import           Control.Lens ((.=))
import           Control.Monad.Except
import           Data.Aeson as A hiding ((.=))
import qualified Data.Text as T

import           Pact.Persist.MPTree (MPTreeDB, persister)
import           Pact.PersistPactDb (DbEnv (..), pactdb, initDbEnv, createSchema)
import           Pact.Types.Gas (Gas (..))
import           Pact.Types.Logger ()
import           Pact.Types.Persistence (TxId (..))
import           Pact.Types.RPC (ExecMsg (..), PactRPC (..))
import           Pact.Types.Server ()
import           Pact.Types.SQLite ()

import           Pos.Chain.Txp.Toil.Failure
import           Pos.Chain.Txp.Toil.Monad
import           Pos.Chain.Txp.Toil.Pact.Command
import           Pos.Chain.Txp.Toil.Pact.Interpreter

import           Sealchain.Mpt.MerklePatricia.MPDB (KVPersister (..))

initSchema :: PactDbEnv (DbEnv p) -> IO ()
initSchema PactDbEnv {..} = createSchema pdPactDbVar

applyCmd 
  :: (MonadIO m, KVPersister p)
  => Command ByteString 
  -> ExceptT ToilVerFailure (PactExecM p m) CommandResult
applyCmd cmd = applyCmd' cmd (verifyCommand cmd)

applyCmd' 
  :: (MonadIO m, KVPersister p)
  => Command a 
  -> ProcessedCommand ParsedCode 
  -> ExceptT ToilVerFailure (PactExecM p m) CommandResult
applyCmd' _ (ProcFail s) = throwError $ ToilPactError (T.pack s)
applyCmd'  _ (ProcSucc cmd) = runPayload cmd

jsonResult :: ToJSON a => Gas -> a -> CommandResult
jsonResult gas a = CommandResult (toJSON a) gas

runPayload 
  :: (MonadIO m, KVPersister p)
  => Command (Payload ParsedCode) 
  -> ExceptT ToilVerFailure (PactExecM p m) CommandResult
runPayload c@Command{..} = case (_pPayload _cmdPayload) of
  Exec pm         -> applyExec pm c
  Continuation _  -> throwError $ ToilPactError "Pact continuation is not supportted for now"

applyExec 
  :: (MonadIO m, KVPersister p)
  => ExecMsg ParsedCode 
  -> Command a 
  -> ExceptT ToilVerFailure (PactExecM p m) CommandResult
applyExec (ExecMsg parsedCode edata) Command{..} = do
  when (null (_pcExps parsedCode)) $ throwError $ ToilPactError "No expressions found"

  refStore <- use pesRefStore
  gasEnv <- view peeGasEnv
  pactDbEnv <- lift $ newPactDbEnv

  let evalEnv = setupEvalEnv pactDbEnv (TxId (1::Word64))
                (MsgData _cmdSigners edata _cmdHash) refStore gasEnv  
  res <- liftIO $ tryAny $ evalExec evalEnv parsedCode
  case res of
    Left (SomeException ex) -> throwError $ ToilPactError $ "Command execution error" <> (show ex)
    Right EvalResult{..} -> do
      when (isJust _erExec) $ throwError $ ToilPactError "Pact execution is not supportted for now"

      dbEnv <- liftIO $ takeMVar (pdPactDbVar pactDbEnv) 
      pesMPTreeDB .= _db dbEnv -- | save new MPTreeDB
      pesRefStore .= _erRefStore

      return $ jsonResult _erGas $ CommandSuccess (Unsafe.last _erOutput)

newPactDbEnv 
  :: (MonadIO m, KVPersister p) 
  => PactExecM p m (PactDbEnv (DbEnv (MPTreeDB p)))
newPactDbEnv = do
  mptDb <- use pesMPTreeDB
  loggers <- view peeLoggers
  let dbe = initDbEnv loggers persister mptDb
  PactDbEnv pactdb <$> newMVar dbe
