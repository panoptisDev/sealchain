{-# LANGUAGE TypeFamilies #-}

-- | Type class necessary for transaction processing (Txp)
-- and some useful getters and setters.

module Pos.DB.Txp.MemState.Class
       ( MonadTxpMem
       , TxpHolderTag
       , withTxpLocalData
       , withTxpLocalDataLog
       , getUtxoModifier
       , getLocalUndos
       , getMemPool
       , getPactState
       , getLocalTxs
       , getLocalTxsMap
       , getTxpExtra
       , getTxpTip
       , setTxpLocalData
       , clearTxpMemPool

       , MonadTxpLocal (..)
       , TxpLocalWorkMode
       , MempoolExt
       ) where

import           Universum

import qualified Control.Concurrent.STM as STM
import           Data.Default (Default (..))
import qualified Data.HashMap.Strict as HM

import           Pos.Chain.Block (HeaderHash)
import           Pos.Chain.Genesis as Genesis (Config)
import           Pos.Chain.Txp (MemPool (..), ToilVerFailure, TxAux, TxId,
                     TxValidationRules, TxpConfiguration, UndoMap,
                     UtxoModifier, PactState, defPactState)
import           Pos.Core.Reporting (MonadReporting)
import           Pos.Core.Slotting (MonadSlots (..))
import           Pos.DB.Class (MonadDBRead, MonadGState (..))
import           Pos.DB.Rocks (MonadRealDB)

import           Pos.DB.Txp.MemState.Types (GenericTxpLocalData (..))
import           Pos.Util.Util (HasLens (..))
import           Pos.Util.Wlog (NamedPureLogger, WithLogger, launchNamedPureLog)

import           Sealchain.Mpt.MerklePatricia.StateRoot (StateRoot)

data TxpHolderTag

-- | More general version of @MonadReader (GenericTxpLocalData mw) m@.
type MonadTxpMem ext ctx m
     = ( MonadReader ctx m
       , HasLens TxpHolderTag ctx (GenericTxpLocalData ext)
       , Default ext
       )

askTxpMem :: MonadTxpMem ext ctx m => m (GenericTxpLocalData ext)
askTxpMem = view (lensOf @TxpHolderTag)

-- | Operate with some or all of the TXP local data.
--
--   Since this function takes an STM action, it can be used to
--   read or modify the components.
withTxpLocalData
    :: (MonadIO m, MonadTxpMem e ctx m)
    => (GenericTxpLocalData e -> STM.STM a) -> m a
withTxpLocalData f = askTxpMem >>= \ld -> atomically (f ld)

-- | Operate with some of all of the TXP local data, allowing
--   logging.
withTxpLocalDataLog
    :: (MonadIO m, MonadTxpMem e ctx m, WithLogger m)
    => (GenericTxpLocalData e -> NamedPureLogger STM.STM a)
    -> m a
withTxpLocalDataLog f = askTxpMem >>=
    \ld -> launchNamedPureLog atomically $ f ld

-- | Read the UTXO modifier from the local TXP data.
getUtxoModifier
    :: GenericTxpLocalData e -> STM.STM UtxoModifier
getUtxoModifier = STM.readTVar . txpUtxoModifier

getLocalTxsMap
    :: GenericTxpLocalData e -> STM.STM (HashMap TxId TxAux)
getLocalTxsMap = fmap _mpLocalTxs . getMemPool

getLocalTxs
    :: GenericTxpLocalData e -> STM.STM [(TxId, TxAux)]
getLocalTxs = fmap HM.toList . getLocalTxsMap

getLocalUndos
    :: GenericTxpLocalData e -> STM.STM UndoMap
getLocalUndos = STM.readTVar . txpUndos

getMemPool
    :: GenericTxpLocalData e -> STM.STM MemPool
getMemPool = STM.readTVar . txpMemPool

getPactState
    :: GenericTxpLocalData e -> STM.STM PactState
getPactState = STM.readTVar . txpPactState

getTxpTip
    :: GenericTxpLocalData e -> STM.STM HeaderHash
getTxpTip = STM.readTVar . txpTip

getTxpExtra
    :: GenericTxpLocalData e -> STM.STM e
getTxpExtra = STM.readTVar . txpExtra

-- | Helper function to set all components of the TxpLocalData.
setTxpLocalData
    :: GenericTxpLocalData e
    -> (UtxoModifier, MemPool, UndoMap, PactState, HeaderHash, e)
    -> STM.STM ()
setTxpLocalData txpData (um, mp, un, ps, hh, e) = do
    STM.writeTVar (txpUtxoModifier txpData) um
    STM.writeTVar (txpMemPool txpData) mp
    STM.writeTVar (txpUndos txpData) un
    STM.writeTVar (txpPactState txpData) ps
    STM.writeTVar (txpTip txpData) hh
    STM.writeTVar (txpExtra txpData) e

-- | Clear everything in local data with the exception of the
--   header tip.
clearTxpMemPool
    :: Default e
    => StateRoot
    -> GenericTxpLocalData e
    -> STM ()
clearTxpMemPool sr txpData = do
  tip <- getTxpTip txpData
  setTxpLocalData txpData (mempty, def, mempty, defPactState sr, tip, def)

----------------------------------------------------------------------------
-- Abstract txNormalize and processTx
----------------------------------------------------------------------------

type family MempoolExt (m :: * -> *) :: *

class Monad m => MonadTxpLocal m where
    txpNormalize :: Genesis.Config -> TxValidationRules -> TxpConfiguration -> m ()
    txpProcessTx :: Genesis.Config -> TxpConfiguration -> (TxId, TxAux) -> m (Either ToilVerFailure ())

type TxpLocalWorkMode ctx m =
    ( MonadIO m
    , MonadDBRead m
    , MonadGState m
    , MonadSlots ctx m
    , MonadTxpMem (MempoolExt m) ctx m
    , WithLogger m
    , MonadMask m
    , MonadReporting m
    , MonadRealDB ctx m
    )
