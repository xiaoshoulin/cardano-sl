{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Functions operating on UTXO.

module Pos.Txp.Txp.Utxo.Functions
       ( verifyTxUtxo
       , applyTxToUtxo
       , applyTxToUtxo'
       , rollbackTxUtxo
       -- * Pure
       , deleteTxIn
       , findTxIn
       , belongsTo
       , filterUtxoByAddr
       , utxoToStakes
       ) where

import           Control.Monad.Error.Class (MonadError (..))
import qualified Data.HashMap.Strict       as HM
import qualified Data.Map.Strict           as M
import qualified Data.Text                 as T
import           Universum

import           Pos.Binary.Types          ()
import           Pos.Crypto                (WithHash (..), hash)
import           Pos.Types                 (Address, Coin, StakeholderId, Tx (..), TxAux,
                                            TxDistribution (..), TxId, TxIn (..),
                                            TxOut (..), TxOutAux, TxUndo, Utxo,
                                            txOutStake, unsafeAddCoin)

import           Pos.Txp.Core.Tx           (VTxGlobalContext (..), VTxLocalContext (..),
                                            verifyTx)
import           Pos.Txp.Txp.Class         (MonadUtxo (..), MonadUtxoRead (..))
import           Pos.Txp.Txp.Failure       (TxpVerFailure (..))

-- CHECK: @verifyTxUtxo
-- | Verify single Tx using MonadUtxoRead as TxIn resolver.
verifyTxUtxo
    :: (MonadUtxoRead m, MonadError TxpVerFailure m)
    => Bool
    -> Bool
    -> TxAux
    -> m TxUndo
verifyTxUtxo verifyAlone verifyVersions txaux = do
    res <- verifyTx verifyAlone verifyVersions VTxGlobalContext utxoGet' txaux
    case res of
        Left errors -> throwError $ TxpInvalid $ T.intercalate ";\n" errors
        Right undo  -> pure undo
  where
    utxoGet' x = fmap VTxLocalContext <$> utxoGet x

-- | Remove unspent outputs used in given transaction, add new unspent
-- outputs.
applyTxToUtxo :: MonadUtxo m => WithHash Tx -> TxDistribution -> m ()
applyTxToUtxo tx distr = do
    mapM_ applyInput txInputs
    mapM_ (uncurry applyOutput)
      (zip [0..] (zip txOutputs (getTxDistribution distr)))
  where
    Tx {..} = whData tx
    applyInput = utxoDel
    applyOutput idx (out, ds) = utxoPut (TxIn (whHash tx) idx) (out, ds)

rollbackTxUtxo
    :: (MonadError TxpVerFailure m, MonadUtxo m)
    => (TxAux, TxUndo) -> m ()
rollbackTxUtxo ((tx@Tx{..}, _, _), undo) = do
    unless (length txInputs == length undo) $
        throwError $ TxpInvalidUndoLength (length txInputs) (length undo)
    let txid = hash tx
    mapM_ utxoDel $ take (length txOutputs) $ zipWith TxIn (repeat txid) [0..]
    mapM_ (uncurry utxoPut) $ zip txInputs undo

applyTxToUtxo' :: MonadUtxo m => (TxId, TxAux) -> m ()
applyTxToUtxo' (i, (t, _, d)) = applyTxToUtxo (WithHash t i) d

-- TODO change types of normalizeTxs and related

----------------------------------------------------------------------------
-- Pure
----------------------------------------------------------------------------

-- | Find transaction input in Utxo assuming it is valid.
findTxIn :: TxIn -> Utxo -> Maybe TxOutAux
findTxIn TxIn{..} = M.lookup (txInHash, txInIndex)

-- | Delete given TxIn from Utxo if any.
deleteTxIn :: TxIn -> Utxo -> Utxo
deleteTxIn TxIn{..} = M.delete (txInHash, txInIndex)

-- | A predicate for `TxOut` which selects outputs for given address
belongsTo :: TxOutAux -> Address -> Bool
(out, _) `belongsTo` addr = addr == txOutAddress out

-- | Select only TxOuts for given addresses
filterUtxoByAddr :: Address -> Utxo -> Utxo
filterUtxoByAddr addr = M.filter (`belongsTo` addr)

utxoToStakes :: Utxo -> HashMap StakeholderId Coin
utxoToStakes = foldl' putDistr mempty . M.toList
  where
    plusAt hm (key, val) = HM.insertWith unsafeAddCoin key val hm
    putDistr hm (_, toaux) = foldl' plusAt hm (txOutStake toaux)
