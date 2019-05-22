{-# LANGUAGE TypeFamilies #-}

-- | Types used for pure transaction processing (aka Toil).

module Pos.Chain.Txp.Toil.Types
       ( Utxo
       , UtxoLookup
       , UtxoModifier
       , formatUtxo
       , utxoF
       , utxoToModifier
       , utxoToLookup

       , StakesView (..)
       , svStakes
       , svTotal

       , TxFee(..)
       , MemPool (..)
       , mpLocalTxs
       , mpSize
       , TxMap
       , UndoMap

       , PactState
       , psRefStore 
       , psPacts
       , psModifier

       , originUtxo
       , gdUtxo
       ) where

import           Universum

import           Control.Lens (makeLenses)
import           Data.ByteString as B (ByteString)
import           Data.Default (Default, def)
import qualified Data.Map as M (Map, lookup, toList, filter, empty)
import           Data.Text.Lazy.Builder (Builder)
import           Formatting (Format, later)
import           Serokell.Util.Text (mapBuilderJson)

import           Pact.Types.Runtime (RefStore, PactExec, PactId)

import           Pos.Chain.Txp.Tx (TxId, TxIn, isOriginTxOut, isGDTxOut)
import           Pos.Chain.Txp.TxAux (TxAux)
import           Pos.Chain.Txp.TxOutAux (TxOutAux (..))
import           Pos.Chain.Txp.Undo (TxUndo)
import           Pos.Core (Coin, StakeholderId)
import qualified Pos.Util.Modifier as MM

----------------------------------------------------------------------------
-- UTXO
----------------------------------------------------------------------------

-- | Unspent transaction outputs.
--
-- Transaction inputs are identified by (transaction ID, index in list of
-- output) pairs.
type Utxo = Map TxIn TxOutAux

-- | Type of function to look up an entry in 'Utxo'.
type UtxoLookup = TxIn -> Maybe TxOutAux

-- | All modifications (additions and deletions) to be applied to 'Utxo'.
type UtxoModifier = MM.MapModifier TxIn TxOutAux

-- | Format 'Utxo' map for showing
formatUtxo :: Utxo -> Builder
formatUtxo = mapBuilderJson . M.toList

-- | Specialized formatter for 'Utxo'.
utxoF :: Format r (Utxo -> r)
utxoF = later formatUtxo

utxoToModifier :: Utxo -> UtxoModifier
utxoToModifier = foldl' (flip $ uncurry MM.insert) mempty . M.toList

utxoToLookup :: Utxo -> UtxoLookup
utxoToLookup = flip M.lookup

----------------------------------------------------------------------------
-- Fee
----------------------------------------------------------------------------

-- | tx.fee = sum(tx.in) - sum (tx.out)
newtype TxFee = TxFee Coin
    deriving (Show, Eq, Ord, Generic, Buildable)

----------------------------------------------------------------------------
-- StakesView
----------------------------------------------------------------------------

data StakesView = StakesView
    { _svStakes :: !(HashMap StakeholderId Coin)
    , _svTotal  :: !(Maybe Coin)
    }

makeLenses ''StakesView

instance Default StakesView where
    def = StakesView mempty Nothing

----------------------------------------------------------------------------
-- MemPool
----------------------------------------------------------------------------

type TxMap = HashMap TxId TxAux

data MemPool = MemPool
    { _mpLocalTxs :: !TxMap
      -- | Number of transactions in the memory pool.
    , _mpSize     :: !Int
    }

makeLenses ''MemPool

instance Default MemPool where
    def =
        MemPool
        { _mpLocalTxs = mempty
        , _mpSize     = 0
        }

----------------------------------------------------------------------------
-- UndoMap 
----------------------------------------------------------------------------

type UndoMap = HashMap TxId TxUndo

----------------------------------------------------------------------------
-- PactState
----------------------------------------------------------------------------

data PactState = PactState
    { _psRefStore :: !RefStore
    , _psPacts    :: !(M.Map PactId PactExec)
    , _psModifier :: !(M.Map B.ByteString B.ByteString)
    }

makeLenses ''PactState

instance Default PactState where
    def =
        PactState
        { _psRefStore = def
        , _psPacts    = M.empty
        , _psModifier = M.empty
        }

----------------------------------------------------------------------------
-- Helper functions 
----------------------------------------------------------------------------

originUtxo :: Utxo -> Utxo
originUtxo = M.filter (isOriginTxOut . toaOut)

gdUtxo :: Utxo -> Utxo
gdUtxo = M.filter (isGDTxOut . toaOut)
