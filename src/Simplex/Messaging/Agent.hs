{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Simplex.Messaging.Agent
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines SMP protocol agent with SQLite persistence.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md
module Simplex.Messaging.Agent
  ( -- * queue-based SMP agent
    getAgentClient,
    runAgentClient,

    -- * SMP agent functional API
    AgentClient (..),
    AgentMonad,
    AgentErrorMonad,
    getSMPAgentClient,
    disconnectAgentClient,
    resumeAgentClient,
    withAgentLock,
    createConnection,
    joinConnection,
    allowConnection,
    acceptContact,
    rejectContact,
    subscribeConnection,
    subscribeConnections,
    getConnectionMessage,
    getNotificationMessage,
    resubscribeConnection,
    resubscribeConnections,
    sendMessage,
    ackMessage,
    switchConnection,
    suspendConnection,
    deleteConnection,
    getConnectionServers,
    setSMPServers,
    setNtfServers,
    setNetworkConfig,
    getNetworkConfig,
    registerNtfToken,
    verifyNtfToken,
    checkNtfToken,
    deleteNtfToken,
    getNtfToken,
    getNtfTokenData,
    toggleConnectionNtfs,
    activateAgent,
    suspendAgent,
    logConnection,
  )
where

import Control.Concurrent.STM (flushTBQueue, retry, stateTVar)
import Control.Logger.Simple (logInfo, showText)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Char8 (ByteString)
import Data.Composition ((.:), (.:.))
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.System (systemToUTCTime)
import Data.Word (Word16)
import qualified Database.SQLite.Simple as DB
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.NtfSubSupervisor
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Client (ProtocolClient (..), ServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Notifications.Protocol (DeviceToken, NtfRegCode (NtfRegCode), NtfTknStatus (..), NtfTokenId)
import Simplex.Messaging.Notifications.Server.Push.APNS (PNMessageData (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol (BrokerMsg, ErrorType (AUTH), MsgBody, MsgFlags, NtfServer, SMPMsgMeta, SndPublicVerifyKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Random (randomR)
import UnliftIO.Async (async, mapConcurrently, race_)
import UnliftIO.Concurrent (forkFinally, forkIO, threadDelay)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- import GHC.Conc (unsafeIOToSTM)

-- | Creates an SMP agent client instance
getSMPAgentClient :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> InitialAgentServers -> m AgentClient
getSMPAgentClient cfg initServers = newSMPAgentEnv cfg >>= runReaderT runAgent
  where
    runAgent = do
      c <- getAgentClient initServers
      void $ race_ (subscriber c) (runNtfSupervisor c) `forkFinally` const (disconnectAgentClient c)
      pure c

disconnectAgentClient :: MonadUnliftIO m => AgentClient -> m ()
disconnectAgentClient c@AgentClient {agentEnv = Env {ntfSupervisor = ns}} = do
  closeAgentClient c
  liftIO $ closeNtfSupervisor ns
  logConnection c False

resumeAgentClient :: MonadIO m => AgentClient -> m ()
resumeAgentClient c = atomically $ writeTVar (active c) True

-- |
type AgentErrorMonad m = (MonadUnliftIO m, MonadError AgentErrorType m)

-- | Create SMP agent connection (NEW command)
createConnection :: AgentErrorMonad m => AgentClient -> Bool -> SConnectionMode c -> m (ConnId, ConnectionRequestUri c)
createConnection c enableNtfs cMode = withAgentEnv c $ newConn c "" enableNtfs cMode

-- | Join SMP agent connection (JOIN command)
joinConnection :: AgentErrorMonad m => AgentClient -> Bool -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConnection c enableNtfs = withAgentEnv c .: joinConn c "" enableNtfs

-- | Allow connection to continue after CONF notification (LET command)
allowConnection :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection c = withAgentEnv c .:. allowConnection' c

-- | Accept contact after REQ notification (ACPT command)
acceptContact :: AgentErrorMonad m => AgentClient -> Bool -> ConfirmationId -> ConnInfo -> m ConnId
acceptContact c enableNtfs = withAgentEnv c .: acceptContact' c "" enableNtfs

-- | Reject contact (RJCT command)
rejectContact :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> m ()
rejectContact c = withAgentEnv c .: rejectContact' c

-- | Subscribe to receive connection messages (SUB command)
subscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
subscribeConnection c = withAgentEnv c . subscribeConnection' c

-- | Subscribe to receive connection messages from multiple connections, batching commands when possible
subscribeConnections :: AgentErrorMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
subscribeConnections c = withAgentEnv c . subscribeConnections' c

-- | Get connection message (GET command)
getConnectionMessage :: AgentErrorMonad m => AgentClient -> ConnId -> m (Maybe SMPMsgMeta)
getConnectionMessage c = withAgentEnv c . getConnectionMessage' c

-- | Get connection message for received notification
getNotificationMessage :: AgentErrorMonad m => AgentClient -> C.CbNonce -> ByteString -> m (NotificationInfo, [SMPMsgMeta])
getNotificationMessage c = withAgentEnv c .: getNotificationMessage' c

resubscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
resubscribeConnection c = withAgentEnv c . resubscribeConnection' c

resubscribeConnections :: AgentErrorMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
resubscribeConnections c = withAgentEnv c . resubscribeConnections' c

-- | Send message to the connection (SEND command)
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> MsgFlags -> MsgBody -> m AgentMsgId
sendMessage c = withAgentEnv c .:. sendMessage' c

ackMessage :: AgentErrorMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage c = withAgentEnv c .: ackMessage' c

-- | Switch connection to the new receive queue
switchConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
switchConnection c = withAgentEnv c . switchConnection' c

-- | Suspend SMP agent connection (OFF command)
suspendConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m Word16
suspendConnection c = withAgentEnv c . suspendConnection' c

-- | Delete SMP agent connection (DEL command)
deleteConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnection c = withAgentEnv c . deleteConnection' c

-- | get servers used for connection
getConnectionServers :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
getConnectionServers c = withAgentEnv c . getConnectionServers' c

-- | Change servers to be used for creating new queues
setSMPServers :: AgentErrorMonad m => AgentClient -> NonEmpty SMPServer -> m ()
setSMPServers c = withAgentEnv c . setSMPServers' c

setNtfServers :: AgentErrorMonad m => AgentClient -> [NtfServer] -> m ()
setNtfServers c = withAgentEnv c . setNtfServers' c

-- | set SOCKS5 proxy on/off and optionally set TCP timeout
setNetworkConfig :: AgentErrorMonad m => AgentClient -> NetworkConfig -> m ()
setNetworkConfig c cfg' = do
  cfg <- atomically $ do
    swapTVar (useNetworkConfig c) cfg'
  liftIO . when (cfg /= cfg') $ do
    closeProtocolServerClients c smpClients
    closeProtocolServerClients c ntfClients

getNetworkConfig :: AgentErrorMonad m => AgentClient -> m NetworkConfig
getNetworkConfig = readTVarIO . useNetworkConfig

-- | Register device notifications token
registerNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> NotificationsMode -> m NtfTknStatus
registerNtfToken c = withAgentEnv c .: registerNtfToken' c

-- | Verify device notifications token
verifyNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> C.CbNonce -> ByteString -> m ()
verifyNtfToken c = withAgentEnv c .:. verifyNtfToken' c

checkNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
checkNtfToken c = withAgentEnv c . checkNtfToken' c

deleteNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m ()
deleteNtfToken c = withAgentEnv c . deleteNtfToken' c

getNtfToken :: AgentErrorMonad m => AgentClient -> m (DeviceToken, NtfTknStatus, NotificationsMode)
getNtfToken c = withAgentEnv c $ getNtfToken' c

getNtfTokenData :: AgentErrorMonad m => AgentClient -> m NtfToken
getNtfTokenData c = withAgentEnv c $ getNtfTokenData' c

-- | Set connection notifications on/off
toggleConnectionNtfs :: AgentErrorMonad m => AgentClient -> ConnId -> Bool -> m ()
toggleConnectionNtfs c = withAgentEnv c .: toggleConnectionNtfs' c

-- | Activate operations
activateAgent :: AgentErrorMonad m => AgentClient -> m ()
activateAgent c = withAgentEnv c $ activateAgent' c

-- | Suspend operations with max delay to deliver pending messages
suspendAgent :: AgentErrorMonad m => AgentClient -> Int -> m ()
suspendAgent c = withAgentEnv c . suspendAgent' c

withAgentEnv :: AgentClient -> ReaderT Env m a -> m a
withAgentEnv c = (`runReaderT` agentEnv c)

-- withAgentClient :: AgentErrorMonad m => AgentClient -> ReaderT Env m a -> m a
-- withAgentClient c = withAgentLock c . withAgentEnv c

-- | Creates an SMP agent client instance that receives commands and sends responses via 'TBQueue's.
getAgentClient :: (MonadUnliftIO m, MonadReader Env m) => InitialAgentServers -> m AgentClient
getAgentClient initServers = ask >>= atomically . newAgentClient initServers

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

-- | Runs an SMP agent instance that receives commands and sends responses via 'TBQueue's.
runAgentClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runAgentClient c = race_ (subscriber c) (client c)

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
client c@AgentClient {rcvQ, subQ} = forever $ do
  (corrId, connId, cmd) <- atomically $ readTBQueue rcvQ
  withAgentLock c (runExceptT $ processCommand c (connId, cmd))
    >>= atomically . writeTBQueue subQ . \case
      Left e -> (corrId, connId, ERR e)
      Right (connId', resp) -> (corrId, connId', resp)

-- | execute any SMP agent command
processCommand :: forall m. AgentMonad m => AgentClient -> (ConnId, ACommand 'Client) -> m (ConnId, ACommand 'Agent)
processCommand c (connId, cmd) = case cmd of
  NEW (ACM cMode) -> second (INV . ACR cMode) <$> newConn c connId True cMode
  JOIN (ACR _ cReq) connInfo -> (,OK) <$> joinConn c connId True cReq connInfo
  LET confId ownCInfo -> allowConnection' c connId confId ownCInfo $> (connId, OK)
  ACPT invId ownCInfo -> (,OK) <$> acceptContact' c connId True invId ownCInfo
  RJCT invId -> rejectContact' c connId invId $> (connId, OK)
  SUB -> subscribeConnection' c connId $> (connId, OK)
  SEND msgFlags msgBody -> (connId,) . MID <$> sendMessage' c connId msgFlags msgBody
  ACK msgId -> ackMessage' c connId msgId $> (connId, OK)
  OFF -> suspendConnection' c connId $> (connId, OK)
  DEL -> deleteConnection' c connId $> (connId, OK)
  CHK -> (connId,) . STAT <$> getConnectionServers' c connId

newConn :: AgentMonad m => AgentClient -> ConnId -> Bool -> SConnectionMode c -> m (ConnId, ConnectionRequestUri c)
newConn c connId enableNtfs cMode = do
  srv <- getAnySMPServer c
  clientVRange <- asks $ smpClientVRange . config
  (rq, qUri) <- newRcvQueue c srv clientVRange True
  g <- asks idsDrg
  connAgentVersion <- asks $ maxVersion . smpAgentVRange . config
  let cData = ConnData {connId, connAgentVersion, enableNtfs, duplexHandshake = Nothing} -- connection mode is determined by the accepting agent
  connId' <- withStore c $ \db -> createRcvConn db g cData rq cMode
  addSubscription c rq connId'
  when enableNtfs $ do
    ns <- asks ntfSupervisor
    atomically $ sendNtfSubCommand ns (connId', NSCCreate)
  aVRange <- asks $ smpAgentVRange . config
  let crData = ConnReqUriData simplexChat aVRange [qUri]
  case cMode of
    SCMContact -> pure (connId', CRContactUri crData)
    SCMInvitation -> do
      (pk1, pk2, e2eRcvParams) <- liftIO $ CR.generateE2EParams CR.e2eEncryptVersion
      withStore' c $ \db -> createRatchetX3dhKeys db connId' pk1 pk2
      pure (connId', CRInvitationUri crData $ toVersionRangeT e2eRcvParams CR.e2eEncryptVRange)

joinConn :: AgentMonad m => AgentClient -> ConnId -> Bool -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConn c connId enableNtfs (CRInvitationUri (ConnReqUriData _ agentVRange (qUri :| _)) e2eRcvParamsUri) cInfo = do
  aVRange <- asks $ smpAgentVRange . config
  clientVRange <- asks $ smpClientVRange . config
  case ( qUri `compatibleVersion` clientVRange,
         e2eRcvParamsUri `compatibleVersion` CR.e2eEncryptVRange,
         agentVRange `compatibleVersion` aVRange
       ) of
    (Just qInfo, Just (Compatible e2eRcvParams@(CR.E2ERatchetParams _ _ rcDHRr)), Just aVersion@(Compatible connAgentVersion)) -> do
      (pk1, pk2, e2eSndParams) <- liftIO . CR.generateE2EParams $ version e2eRcvParams
      (_, rcDHRs) <- liftIO C.generateKeyPair'
      let rc = CR.initSndRatchet rcDHRr rcDHRs $ CR.x3dhSnd pk1 pk2 e2eRcvParams
      sq <- newSndQueue qInfo True
      g <- asks idsDrg
      let duplexHS = connAgentVersion /= 1
          cData = ConnData {connId, connAgentVersion, enableNtfs, duplexHandshake = Just duplexHS}
      connId' <- withStore c $ \db -> runExceptT $ do
        connId' <- ExceptT $ createSndConn db g cData sq
        liftIO $ createRatchet db connId' rc
        pure connId'
      let cData' = (cData :: ConnData) {connId = connId'}
      tryError (confirmQueue aVersion c cData' sq cInfo $ Just e2eSndParams) >>= \case
        Right _ -> do
          unless duplexHS . void $ enqueueMessage c cData' sq SMP.noMsgFlags HELLO
          pure connId'
        Left e -> do
          -- TODO recovery for failure on network timeout, see rfcs/2022-04-20-smp-conf-timeout-recovery.md
          withStore' c (`deleteConn` connId')
          throwError e
    _ -> throwError $ AGENT A_VERSION
joinConn c connId enableNtfs (CRContactUri (ConnReqUriData _ agentVRange (qUri :| _))) cInfo = do
  aVRange <- asks $ smpAgentVRange . config
  clientVRange <- asks $ smpClientVRange . config
  case ( qUri `compatibleVersion` clientVRange,
         agentVRange `compatibleVersion` aVRange
       ) of
    (Just qInfo, Just vrsn) -> do
      (connId', cReq) <- newConn c connId enableNtfs SCMInvitation
      sendInvitation c qInfo vrsn cReq cInfo
      pure connId'
    _ -> throwError $ AGENT A_VERSION

createReplyQueue :: AgentMonad m => AgentClient -> ConnData -> SndQueue -> m SMPQueueInfo
createReplyQueue c ConnData {connId, enableNtfs} SndQueue {server, smpClientVersion} = do
  srv <- getSMPServer c server
  (rq, qUri) <- newRcvQueue c srv (versionToRange smpClientVersion) True
  let qInfo = toVersionT qUri smpClientVersion
  addSubscription c rq connId
  withStore c $ \db -> upgradeSndConnToDuplex db connId rq
  when enableNtfs $ do
    ns <- asks ntfSupervisor
    atomically $ sendNtfSubCommand ns (connId, NSCCreate)
  pure qInfo

-- | Approve confirmation (LET command) in Reader monad
allowConnection' :: AgentMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection' c connId confId ownConnInfo =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (RcvConnection cData rq) -> do
      AcceptedConfirmation {senderConf} <- withStore c $ \db -> runExceptT $ do
        conf <- ExceptT $ acceptConfirmation db confId ownConnInfo
        liftIO $ createRatchet db connId $ ratchetState (conf :: AcceptedConfirmation)
        pure conf
      processConfirmation c rq senderConf
      mapM_ (connectReplyQueues c cData ownConnInfo) (L.nonEmpty $ smpReplyQueues senderConf)
    _ -> throwError $ CMD PROHIBITED

-- | Accept contact (ACPT command) in Reader monad
acceptContact' :: AgentMonad m => AgentClient -> ConnId -> Bool -> InvitationId -> ConnInfo -> m ConnId
acceptContact' c connId enableNtfs invId ownConnInfo = do
  Invitation {contactConnId, connReq} <- withStore c (`getInvitation` invId)
  withStore c (`getConn` contactConnId) >>= \case
    SomeConn _ ContactConnection {} -> do
      withStore' c $ \db -> acceptInvitation db invId ownConnInfo
      joinConn c connId enableNtfs connReq ownConnInfo `catchError` \err -> do
        withStore' c (`unacceptInvitation` invId)
        throwError err
    _ -> throwError $ CMD PROHIBITED

-- | Reject contact (RJCT command) in Reader monad
rejectContact' :: AgentMonad m => AgentClient -> ConnId -> InvitationId -> m ()
rejectContact' c contactConnId invId =
  withStore c $ \db -> deleteInvitation db contactConnId invId

processConfirmation :: AgentMonad m => AgentClient -> RcvQueue -> SMPConfirmation -> m ()
processConfirmation c rq@RcvQueue {e2ePrivKey, smpClientVersion = v} SMPConfirmation {senderKey, e2ePubKey, smpClientVersion = v'} = do
  let dhSecret = C.dh' e2ePubKey e2ePrivKey
  withStore' c $ \db -> setRcvQueueConfirmedE2E db rq senderKey dhSecret $ min v v'
  -- TODO if this call to secureQueue fails the connection will not complete
  -- add secure rcv queue on subscription
  secureQueue c rq senderKey
  withStore' c $ \db -> setRcvQueueStatus db rq Secured

-- | Subscribe to receive connection messages (SUB command) in Reader monad
subscribeConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
subscribeConnection' c connId =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection cData rq sq _ _) -> do
      resumeMsgDelivery c cData sq
      subscribe rq
      void . forkIO $ doRcvQueueAction c cData rq sq
    SomeConn _ (SndConnection cData sq) -> do
      resumeMsgDelivery c cData sq
      case status (sq :: SndQueue) of
        Confirmed -> pure () -- TODO secure queue if this is a new server version
        Active -> throwError $ CONN SIMPLEX
        _ -> throwError $ INTERNAL "unexpected queue status"
    SomeConn _ (RcvConnection _ rq) -> subscribe rq
    SomeConn _ (ContactConnection _ rq) -> subscribe rq
  where
    -- TODO sndQueueAction?
    subscribe :: RcvQueue -> m ()
    subscribe rq = do
      subscribeQueue c rq connId
      ns <- asks ntfSupervisor
      atomically $ sendNtfSubCommand ns (connId, NSCCreate)

-- TODO expire actions
doRcvQueueAction :: AgentMonad m => AgentClient -> ConnData -> RcvQueue -> SndQueue -> m ()
doRcvQueueAction c cData rq@RcvQueue {rcvQueueAction} sq =
  forM_ rcvQueueAction $ \(a, _ts) -> case a of
    RQACreateNextQueue -> createNextRcvQueue c cData rq sq
    RQASecureNextQueue -> withNextRcvQueue secureNextRcvQueue
    RQASuspendCurrQueue -> withNextRcvQueue suspendCurrRcvQueue
    RQADeleteCurrQueue -> withNextRcvQueue deleteCurrRcvQueue
  where
    withNextRcvQueue :: AgentMonad m => (AgentClient -> ConnData -> RcvQueue -> SndQueue -> RcvQueue -> m ()) -> m ()
    withNextRcvQueue action = do
      withStore' c (`getNextRcvQueue` rq) >>= \case
        Just rq' -> action c cData rq sq rq'
        _ -> do
          -- notify agent internal error
          pure ()

createNextRcvQueue :: AgentMonad m => AgentClient -> ConnData -> RcvQueue -> SndQueue -> m ()
createNextRcvQueue c cData@ConnData {connId} rq@RcvQueue {server, sndId} sq = do
  clientVRange <- asks $ smpClientVRange . config
  nextQueueUri <-
    withStore' c (`getNextRcvQueue` rq) >>= \case
      Just RcvQueue {server = smpServer, sndId = senderId, e2ePrivKey} -> do
        let queueAddress = SMPQueueAddress {smpServer, senderId, dhPublicKey = C.publicKey e2ePrivKey}
        pure SMPQueueUri {clientVRange, queueAddress}
      _ -> do
        srv <- getSMPServer c server
        (rq', qUri) <- newRcvQueue c srv clientVRange False
        withStore' c $ \db -> dbCreateNextRcvQueue db connId rq rq'
        pure qUri
  void $ enqueueMessage c cData sq SMP.noMsgFlags QNEW {currentAddress = (server, sndId), nextQueueUri}
  withStore' c $ \db -> setRcvQueueAction db rq Nothing

secureNextRcvQueue :: AgentMonad m => AgentClient -> ConnData -> RcvQueue -> SndQueue -> RcvQueue -> m ()
secureNextRcvQueue c cData rq sq rq'@RcvQueue {server, sndId, status, sndPublicKey} = do
  when (status == Confirmed) $ case sndPublicKey of
    Just sKey -> do
      secureQueue c rq sKey
      withStore' c $ \db -> setRcvQueueStatus db rq' Secured
    _ -> do
      -- notify user: no sender key
      pure ()
  void . enqueueMessage c cData sq SMP.noMsgFlags $ QREADY (server, sndId)
  withStore' c $ \db -> setRcvQueueAction db rq Nothing

suspendCurrRcvQueue :: AgentMonad m => AgentClient -> ConnData -> RcvQueue -> SndQueue -> RcvQueue -> m ()
suspendCurrRcvQueue c cData rq sq rq' = do
  msgCount <- suspendQueue c rq
  withStore' c $ \db -> setRcvQueueStatus db rq Disabled
  when (msgCount == 0) $ currRcvQueueDrained c cData rq sq rq'

currRcvQueueDrained :: AgentMonad m => AgentClient -> ConnData -> RcvQueue -> SndQueue -> RcvQueue -> m ()
currRcvQueueDrained c cData rq sq rq' = do
  withStore' c $ \db -> setRcvQueueAction db rq $ Just RQADeleteCurrQueue
  deleteCurrRcvQueue c cData rq sq rq'

deleteCurrRcvQueue :: AgentMonad m => AgentClient -> ConnData -> RcvQueue -> SndQueue -> RcvQueue -> m ()
deleteCurrRcvQueue c cData@ConnData {connId} rq sq rq'@RcvQueue {server, rcvId} = do
  deleteQueue c rq
  withStore' c $ \db -> switchCurrRcvQueue db rq rq'
  atomically $
    TM.lookupDelete (server, rcvId) (nextRcvQueueMsgs c)
      >>= mapM_ ((mapM_ . writeTBQueue $ msgQ c) . reverse)
  sq' <- withStore' c (`getNextSndQueue` sq)
  let sStats = connectionStats $ DuplexConnection cData rq' sq Nothing sq'
  atomically $ writeTBQueue (subQ c) ("", connId, SWITCH SPCompleted sStats)

subscribeConnections' :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
subscribeConnections' _ [] = pure M.empty
subscribeConnections' c connIds = do
  conns :: Map ConnId (Either StoreError SomeConn) <- M.fromList . zip connIds <$> withStore' c (forM connIds . getConn)
  let (errs, cs) = M.mapEither id conns
      errs' = M.map (Left . storeError) errs
      (sndQs, rcvQs) = M.mapEither rcvOrSndQueue cs
      sndRs = M.map (sndSubResult . fst) sndQs
      srvRcvQs :: Map SMPServer (Map ConnId (RcvQueue, ConnData)) = M.foldlWithKey' addRcvQueue M.empty rcvQs
  mapM_ (mapM_ (uncurry $ resumeMsgDelivery c) . sndQueue) cs
  rcvRs <- mapConcurrently subscribe (M.assocs srvRcvQs)
  ns <- asks ntfSupervisor
  tkn <- readTVarIO (ntfTkn ns)
  when (instantNotifications tkn) . void . forkIO $ sendNtfCreate ns rcvRs
  let rs = M.unions $ errs' : sndRs : rcvRs
  notifyResultError rs
  void . forkIO . forM_ cs $ \case
    SomeConn _ (DuplexConnection cData rq sq _ _) -> doRcvQueueAction c cData rq sq
    _ -> pure ()
  -- TODO secure Confirmed queues if this is a new server version
  pure rs
  where
    rcvOrSndQueue :: SomeConn -> Either (SndQueue, ConnData) (RcvQueue, ConnData)
    rcvOrSndQueue = \case
      SomeConn _ (DuplexConnection cData rq _ _ _) -> Right (rq, cData)
      SomeConn _ (SndConnection cData sq) -> Left (sq, cData)
      SomeConn _ (RcvConnection cData rq) -> Right (rq, cData)
      SomeConn _ (ContactConnection cData rq) -> Right (rq, cData)
    sndSubResult :: SndQueue -> Either AgentErrorType ()
    sndSubResult sq = case status (sq :: SndQueue) of
      Confirmed -> Right ()
      Active -> Left $ CONN SIMPLEX
      _ -> Left $ INTERNAL "unexpected queue status"
    addRcvQueue :: Map SMPServer (Map ConnId (RcvQueue, ConnData)) -> ConnId -> (RcvQueue, ConnData) -> Map SMPServer (Map ConnId (RcvQueue, ConnData))
    addRcvQueue m connId rq@(RcvQueue {server}, _) = M.alter (Just . maybe (M.singleton connId rq) (M.insert connId rq)) server m
    subscribe :: (SMPServer, Map ConnId (RcvQueue, ConnData)) -> m (Map ConnId (Either AgentErrorType ()))
    subscribe (srv, qs) = snd <$> subscribeQueues c srv (M.map fst qs)
    sendNtfCreate :: NtfSupervisor -> [Map ConnId (Either AgentErrorType ())] -> m ()
    sendNtfCreate ns rcvRs =
      forM_ (concatMap M.assocs rcvRs) $ \case
        (connId, Right _) -> atomically $ writeTBQueue (ntfSubQ ns) (connId, NSCCreate)
        _ -> pure ()
    sndQueue :: SomeConn -> Maybe (ConnData, SndQueue)
    sndQueue = \case
      SomeConn _ (DuplexConnection cData _ sq _ _) -> Just (cData, sq)
      SomeConn _ (SndConnection cData sq) -> Just (cData, sq)
      _ -> Nothing
    notifyResultError :: Map ConnId (Either AgentErrorType ()) -> m ()
    notifyResultError rs = do
      let actual = M.size rs
          expected = length connIds
      when (actual /= expected) . atomically $
        writeTBQueue (subQ c) ("", "", ERR . INTERNAL $ "subscribeConnections result size: " <> show actual <> ", expected " <> show expected)

resubscribeConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
resubscribeConnection' c connId =
  unlessM
    (atomically $ hasActiveSubscription c connId)
    (subscribeConnection' c connId)

resubscribeConnections' :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
resubscribeConnections' _ [] = pure M.empty
resubscribeConnections' c connIds = do
  let r = M.fromList . zip connIds . repeat $ Right ()
  connIds' <- filterM (fmap not . atomically . hasActiveSubscription c) connIds
  -- union is left-biased, so results returned by subscribeConnections' take precedence
  (`M.union` r) <$> subscribeConnections' c connIds'

getConnectionMessage' :: AgentMonad m => AgentClient -> ConnId -> m (Maybe SMPMsgMeta)
getConnectionMessage' c connId = do
  whenM (atomically $ hasActiveSubscription c connId) . throwError $ CMD PROHIBITED
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _ _ _) -> getQueueMessage c rq
    SomeConn _ (RcvConnection _ rq) -> getQueueMessage c rq
    SomeConn _ (ContactConnection _ rq) -> getQueueMessage c rq
    SomeConn _ SndConnection {} -> throwError $ CONN SIMPLEX

getNotificationMessage' :: forall m. AgentMonad m => AgentClient -> C.CbNonce -> ByteString -> m (NotificationInfo, [SMPMsgMeta])
getNotificationMessage' c nonce encNtfInfo = do
  withStore' c getActiveNtfToken >>= \case
    Just NtfToken {ntfDhSecret = Just dhSecret} -> do
      ntfData <- agentCbDecrypt dhSecret nonce encNtfInfo
      PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta} <- liftEither (parse strP (INTERNAL "error parsing PNMessageData") ntfData)
      (ntfConnId, rcvNtfDhSecret) <- withStore c (`getNtfRcvQueue` smpQueue)
      ntfMsgMeta <- (eitherToMaybe . smpDecode <$> agentCbDecrypt rcvNtfDhSecret nmsgNonce encNMsgMeta) `catchError` \_ -> pure Nothing
      maxMsgs <- asks $ ntfMaxMessages . config
      (NotificationInfo {ntfConnId, ntfTs, ntfMsgMeta},) <$> getNtfMessages ntfConnId maxMsgs ntfMsgMeta []
    _ -> throwError $ CMD PROHIBITED
  where
    getNtfMessages ntfConnId maxMs nMeta ms
      | length ms < maxMs =
        getConnectionMessage' c ntfConnId >>= \case
          Just m@SMP.SMPMsgMeta {msgId, msgTs, msgFlags} -> case nMeta of
            Just SMP.NMsgMeta {msgId = msgId', msgTs = msgTs'}
              | msgId == msgId' || msgTs > msgTs' -> pure $ reverse (m : ms)
              | otherwise -> getMsg (m : ms)
            _
              | SMP.notification msgFlags -> pure $ reverse (m : ms)
              | otherwise -> getMsg (m : ms)
          _ -> pure $ reverse ms
      | otherwise = pure $ reverse ms
      where
        getMsg = getNtfMessages ntfConnId maxMs nMeta

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> MsgFlags -> MsgBody -> m AgentMsgId
sendMessage' c connId msgFlags msg =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection cData _ sq _ _) -> enqueueMsg cData sq
    SomeConn _ (SndConnection cData sq) -> enqueueMsg cData sq
    _ -> throwError $ CONN SIMPLEX
  where
    enqueueMsg :: ConnData -> SndQueue -> m AgentMsgId
    enqueueMsg cData sq = enqueueMessage c cData sq msgFlags $ A_MSG msg

enqueueMessage :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> MsgFlags -> AMessage -> m AgentMsgId
enqueueMessage c cData@ConnData {connId, connAgentVersion} sq msgFlags aMessage = do
  resumeMsgDelivery c cData sq
  msgId <- storeSentMsg
  queuePendingMsgs c sq [msgId]
  pure $ unId msgId
  where
    storeSentMsg :: m InternalId
    storeSentMsg = withStore c $ \db -> runExceptT $ do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
      let privHeader = APrivHeader (unSndId internalSndId) prevMsgHash
          agentMsg = AgentMessage privHeader aMessage
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      encAgentMessage <- agentRatchetEncrypt db connId agentMsgStr e2eEncUserMsgLength
      let msgBody = smpEncode $ AgentMsgEnvelope {agentVersion = connAgentVersion, encAgentMessage}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgFlags, msgBody, internalHash, prevMsgHash}
      liftIO $ createSndMsg db connId msgData
      pure internalId

resumeMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> m ()
resumeMsgDelivery c cData@ConnData {connId} sq@SndQueue {server, sndId} = do
  let qKey = (server, sndId)
  unlessM (queueDelivering qKey) $ do
    mq <- atomically $ getPendingMsgQ c sq
    async (runSmpQueueMsgDelivery c cData mq)
      >>= \a -> atomically (TM.insert qKey a $ smpQueueMsgDeliveries c)
  unlessM connQueued $
    withStore' c (`getPendingMsgs` connId)
      >>= queuePendingMsgs c sq
  where
    queueDelivering qKey = atomically $ TM.member qKey (smpQueueMsgDeliveries c)
    connQueued = atomically $ isJust <$> TM.lookupInsert connId True (connMsgsQueued c)

queuePendingMsgs :: AgentMonad m => AgentClient -> SndQueue -> [InternalId] -> m ()
queuePendingMsgs c sq msgIds = atomically $ do
  modifyTVar' (msgDeliveryOp c) $ \s -> s {opsInProgress = opsInProgress s + length msgIds}
  -- s <- readTVar (msgDeliveryOp c)
  -- unsafeIOToSTM $ putStrLn $ "msgDeliveryOp: " <> show (opsInProgress s)
  q <- getPendingMsgQ c sq
  mapM_ (writeTQueue q) msgIds

getPendingMsgQ :: AgentClient -> SndQueue -> STM (TQueue InternalId)
getPendingMsgQ c SndQueue {server, sndId} = do
  let qKey = (server, sndId)
  maybe (newMsgQueue qKey) pure =<< TM.lookup qKey (smpQueueMsgQueues c)
  where
    newMsgQueue qKey = do
      mq <- newTQueue
      TM.insert qKey mq $ smpQueueMsgQueues c
      pure mq

runSmpQueueMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnData -> TQueue InternalId -> m ()
runSmpQueueMsgDelivery c@AgentClient {subQ} cData@ConnData {connId, duplexHandshake} mq = do
  ri <- asks $ messageRetryInterval . config
  forever $ do
    atomically $ endAgentOperation c AOSndNetwork
    msgId <- atomically $ readTQueue mq
    atomically $ do
      beginAgentOperation c AOSndNetwork
      endAgentOperation c AOMsgDelivery
    let mId = unId msgId
    E.try (withStore c $ \db -> getPendingMsgData db connId msgId) >>= \case
      Left (e :: E.SomeException) ->
        notify $ MERR mId (INTERNAL $ show e)
      Right (rq_, sq, PendingMsgData {msgType, msgBody, msgFlags, internalTs}) ->
        withRetryInterval ri $ \loop -> do
          resp <- tryError $ case msgType of
            AM_CONN_INFO -> sendConfirmation c sq msgBody
            _ -> sendAgentMessage c sq msgFlags msgBody
          case resp of
            Left e -> do
              let err = if msgType == AM_CONN_INFO then ERR e else MERR mId e
              case e of
                SMP SMP.QUOTA -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_CONN_INFO_REPLY -> connError msgId NOT_AVAILABLE
                  AM_QTEST_ -> do
                    -- cancel switching, delete new send queue
                    pure ()
                  AM_QHELLO_ -> do
                    -- cancel switching, delete new send queue
                    pure ()
                  _ -> retrySending loop
                SMP SMP.AUTH -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_CONN_INFO_REPLY -> connError msgId NOT_AVAILABLE
                  AM_HELLO_
                    -- in duplexHandshake mode (v2) HELLO is only sent once, without retrying,
                    -- because the queue must be secured by the time the confirmation or the first HELLO is received
                    | duplexHandshake == Just True -> connErr
                    | otherwise ->
                      ifM (msgExpired helloTimeout) connErr (retrySending loop)
                    where
                      connErr = case rq_ of
                        -- party initiating connection
                        Just _ -> connError msgId NOT_AVAILABLE
                        -- party joining connection
                        _ -> connError msgId NOT_ACCEPTED
                  AM_REPLY_ -> notifyDel msgId $ ERR e
                  AM_A_MSG_ -> notifyDel msgId $ MERR mId e
                  AM_QNEW_ -> pure ()
                  AM_QKEYS_ -> do
                    -- TODO new send queue status = Confirmed
                    pure ()
                  AM_QREADY_ -> pure ()
                  AM_QTEST_ -> do
                    -- cancel switching, delete new send queue
                    pure ()
                  AM_QSWITCH_ -> pure ()
                  AM_QHELLO_ -> do
                    -- cancel switching, delete new send queue
                    pure ()
                _
                  -- for other operations BROKER HOST is treated as a permanent error (e.g., when connecting to the server),
                  -- the message sending would be retried
                  | temporaryAgentError e || e == BROKER HOST -> do
                    let timeoutSel = if msgType == AM_HELLO_ then helloTimeout else messageTimeout
                    ifM (msgExpired timeoutSel) (notifyDel msgId err) (retrySending loop)
                  | otherwise -> notifyDel msgId err
              where
                msgExpired timeoutSel = do
                  msgTimeout <- asks $ timeoutSel . config
                  currentTime <- liftIO getCurrentTime
                  pure $ diffUTCTime currentTime internalTs > msgTimeout
            Right () -> do
              case msgType of
                AM_CONN_INFO -> do
                  withStore' c $ \db -> do
                    setSndQueueStatus db sq Confirmed
                    when (isJust rq_) $ removeConfirmations db connId
                  -- TODO possibly notification flag should be ON for one of the parties, to result in contact connected notification
                  unless (duplexHandshake == Just True) . void $ enqueueMessage c cData sq SMP.noMsgFlags HELLO
                AM_HELLO_ -> do
                  withStore' c $ \db -> setSndQueueStatus db sq Active
                  case rq_ of
                    -- party initiating connection (in v1)
                    Just RcvQueue {status} ->
                      -- If initiating party were to send CON to the user without waiting for reply HELLO (to reduce handshake time),
                      -- it would lead to the non-deterministic internal ID of the first sent message, at to some other race conditions,
                      -- because it can be sent before HELLO is received
                      -- With `status == Aclive` condition, CON is sent here only by the accepting party, that previously received HELLO
                      when (status == Active) $ notify CON
                    -- Party joining connection sends REPLY after HELLO in v1,
                    -- it is an error to send REPLY in duplexHandshake mode (v2),
                    -- and this branch should never be reached as receive is created before the confirmation,
                    -- so the condition is not necessary here, strictly speaking.
                    _ -> unless (duplexHandshake == Just True) $ do
                      qInfo <- createReplyQueue c cData sq
                      void . enqueueMessage c cData sq SMP.noMsgFlags $ REPLY [qInfo]
                AM_A_MSG_ -> notify $ SENT mId
                AM_QHELLO_ -> do
                  -- withStore' c $ \db -> setSndQueueStatus db sq Active
                  -- what else should happen here?
                  pure ()
                _ -> pure ()
              delMsg msgId
  where
    delMsg :: InternalId -> m ()
    delMsg msgId = withStore' c $ \db -> deleteMsg db connId msgId
    notify :: ACommand 'Agent -> m ()
    notify cmd = atomically $ writeTBQueue subQ ("", connId, cmd)
    notifyDel :: InternalId -> ACommand 'Agent -> m ()
    notifyDel msgId cmd = notify cmd >> delMsg msgId
    connError msgId = notifyDel msgId . ERR . CONN
    retrySending loop = do
      -- end... is in a separate atomically because if begin... blocks, SUSPENDED won't be sent
      atomically $ endAgentOperation c AOSndNetwork
      atomically $ beginAgentOperation c AOSndNetwork
      loop

ackMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage' c connId msgId = do
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _ _ _) -> ack rq
    SomeConn _ (RcvConnection _ rq) -> ack rq
    SomeConn _ (SndConnection _ _) -> throwError $ CONN SIMPLEX
    SomeConn _ (ContactConnection _ _) -> throwError $ CMD PROHIBITED
  where
    ack :: RcvQueue -> m ()
    ack rq = do
      let mId = InternalId msgId
      srvMsgId <- withStore c $ \db -> setMsgUserAck db connId mId
      sendAck c rq srvMsgId `catchError` \case
        SMP SMP.NO_MSG -> pure ()
        e -> throwError e
      withStore' c $ \db -> deleteMsg db connId mId

-- | Switch connection to the new receive queue
switchConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
switchConnection' c connId =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection cData rq sq _ _) -> do
      -- TODO check that rotation is possible (whether the current server supports it)
      withStore' c $ \db -> setRcvQueueAction db rq $ Just RQACreateNextQueue
      createNextRcvQueue c cData rq sq
    SomeConn _ SndConnection {} -> throwError $ CONN SIMPLEX
    _ -> throwError $ CMD PROHIBITED

-- | Suspend SMP agent connection (OFF command) in Reader monad
suspendConnection' :: AgentMonad m => AgentClient -> ConnId -> m Word16
suspendConnection' c connId =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _ _ _) -> suspendQueue c rq
    SomeConn _ (RcvConnection _ rq) -> suspendQueue c rq
    SomeConn _ (ContactConnection _ rq) -> suspendQueue c rq
    SomeConn _ (SndConnection _ _) -> throwError $ CONN SIMPLEX

-- | Delete SMP agent connection (DEL command) in Reader monad
deleteConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
deleteConnection' c connId =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _ nextRq_ _) -> delete rq >> mapM_ (deleteQueue c) nextRq_
    SomeConn _ (RcvConnection _ rq) -> delete rq
    SomeConn _ (ContactConnection _ rq) -> delete rq
    SomeConn _ (SndConnection _ _) -> withStore' c (`deleteConn` connId)
  where
    delete :: RcvQueue -> m ()
    delete rq = do
      deleteQueue c rq
      atomically $ removeSubscription c connId
      withStore' c (`deleteConn` connId)
      ns <- asks ntfSupervisor
      atomically $ writeTBQueue (ntfSubQ ns) (connId, NSCDelete)

getConnectionServers' :: AgentMonad m => AgentClient -> ConnId -> m ConnectionStats
getConnectionServers' c connId = do
  SomeConn _ conn <- withStore c (`getConn` connId)
  pure $ connectionStats conn

connectionStats :: Connection c -> ConnectionStats
connectionStats conn = case conn of
  RcvConnection _ rq -> ConnectionStats {rcvServers = rcvSrvs rq, sndServers = [], nextRcvServers = [], nextSndServers = []}
  SndConnection _ sq -> ConnectionStats {rcvServers = [], sndServers = sndSrvs sq, nextRcvServers = [], nextSndServers = []}
  DuplexConnection _ rq sq nextRq_ nextSq_ -> ConnectionStats {rcvServers = rcvSrvs rq, sndServers = sndSrvs sq, nextRcvServers = maybe [] rcvSrvs nextRq_, nextSndServers = maybe [] sndSrvs nextSq_}
  ContactConnection _ rq -> ConnectionStats {rcvServers = rcvSrvs rq, sndServers = [], nextRcvServers = [], nextSndServers = []}
  where
    rcvSrvs RcvQueue {server} = [server]
    sndSrvs SndQueue {server} = [server]

-- | Change servers to be used for creating new queues, in Reader monad
setSMPServers' :: AgentMonad m => AgentClient -> NonEmpty SMPServer -> m ()
setSMPServers' c = atomically . writeTVar (smpServers c)

registerNtfToken' :: forall m. AgentMonad m => AgentClient -> DeviceToken -> NotificationsMode -> m NtfTknStatus
registerNtfToken' c suppliedDeviceToken suppliedNtfMode =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken, ntfTokenId, ntfTknStatus, ntfTknAction, ntfMode = savedNtfMode} -> do
      status <- case (ntfTokenId, ntfTknAction) of
        (Nothing, Just NTARegister) -> do
          when (savedDeviceToken /= suppliedDeviceToken) $ withStore' c $ \db -> updateDeviceToken db tkn suppliedDeviceToken
          registerToken tkn $> NTRegistered
        -- TODO minimal time before repeat registration
        (Just tknId, Nothing)
          | savedDeviceToken == suppliedDeviceToken ->
            when (ntfTknStatus == NTRegistered) (registerToken tkn) $> NTRegistered
          | otherwise -> replaceToken tknId
        (Just tknId, Just (NTAVerify code))
          | savedDeviceToken == suppliedDeviceToken ->
            t tkn (NTActive, Just NTACheck) $ agentNtfVerifyToken c tknId tkn code
          | otherwise -> replaceToken tknId
        (Just tknId, Just NTACheck)
          | savedDeviceToken == suppliedDeviceToken -> do
            ns <- asks ntfSupervisor
            atomically $ nsUpdateToken ns tkn {ntfMode = suppliedNtfMode}
            when (ntfTknStatus == NTActive) $ do
              cron <- asks $ ntfCron . config
              agentNtfEnableCron c tknId tkn cron
              when (suppliedNtfMode == NMInstant) $ initializeNtfSubs c
              when (suppliedNtfMode == NMPeriodic && savedNtfMode == NMInstant) $ deleteNtfSubs c NSCDelete
            pure ntfTknStatus -- TODO
            -- agentNtfCheckToken c tknId tkn >>= \case
          | otherwise -> replaceToken tknId
        (Just tknId, Just NTADelete) -> do
          agentNtfDeleteToken c tknId tkn
          withStore' c (`removeNtfToken` tkn)
          ns <- asks ntfSupervisor
          atomically $ nsRemoveNtfToken ns
          pure NTExpired
        _ -> pure ntfTknStatus
      withStore' c $ \db -> updateNtfMode db tkn suppliedNtfMode
      pure status
      where
        replaceToken :: NtfTokenId -> m NtfTknStatus
        replaceToken tknId = do
          ns <- asks ntfSupervisor
          tryReplace ns `catchError` \e ->
            if temporaryAgentError e || e == BROKER HOST
              then throwError e
              else do
                withStore' c $ \db -> removeNtfToken db tkn
                atomically $ nsRemoveNtfToken ns
                createToken
          where
            tryReplace ns = do
              agentNtfReplaceToken c tknId tkn suppliedDeviceToken
              withStore' c $ \db -> updateDeviceToken db tkn suppliedDeviceToken
              atomically $ nsUpdateToken ns tkn {deviceToken = suppliedDeviceToken, ntfTknStatus = NTRegistered, ntfMode = suppliedNtfMode}
              pure NTRegistered
    _ -> createToken
  where
    t tkn = withToken c tkn Nothing
    createToken :: m NtfTknStatus
    createToken =
      getNtfServer c >>= \case
        Just ntfServer ->
          asks (cmdSignAlg . config) >>= \case
            C.SignAlg a -> do
              tknKeys <- liftIO $ C.generateSignatureKeyPair a
              dhKeys <- liftIO C.generateKeyPair'
              let tkn = newNtfToken suppliedDeviceToken ntfServer tknKeys dhKeys suppliedNtfMode
              withStore' c (`createNtfToken` tkn)
              registerToken tkn
              pure NTRegistered
        _ -> throwError $ CMD PROHIBITED
    registerToken :: NtfToken -> m ()
    registerToken tkn@NtfToken {ntfPubKey, ntfDhKeys = (pubDhKey, privDhKey)} = do
      (tknId, srvPubDhKey) <- agentNtfRegisterToken c tkn ntfPubKey pubDhKey
      let dhSecret = C.dh' srvPubDhKey privDhKey
      withStore' c $ \db -> updateNtfTokenRegistration db tkn tknId dhSecret
      ns <- asks ntfSupervisor
      atomically $ nsUpdateToken ns tkn {deviceToken = suppliedDeviceToken, ntfTknStatus = NTRegistered, ntfMode = suppliedNtfMode}

verifyNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> C.CbNonce -> ByteString -> m ()
verifyNtfToken' c deviceToken nonce code =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken, ntfTokenId = Just tknId, ntfDhSecret = Just dhSecret, ntfMode} -> do
      when (deviceToken /= savedDeviceToken) . throwError $ CMD PROHIBITED
      code' <- liftEither . bimap cryptoError NtfRegCode $ C.cbDecrypt dhSecret nonce code
      toStatus <-
        withToken c tkn (Just (NTConfirmed, NTAVerify code')) (NTActive, Just NTACheck) $
          agentNtfVerifyToken c tknId tkn code'
      when (toStatus == NTActive) $ do
        cron <- asks $ ntfCron . config
        agentNtfEnableCron c tknId tkn cron
        when (ntfMode == NMInstant) $ initializeNtfSubs c
    _ -> throwError $ CMD PROHIBITED

checkNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
checkNtfToken' c deviceToken =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken, ntfTokenId = Just tknId} -> do
      when (deviceToken /= savedDeviceToken) . throwError $ CMD PROHIBITED
      agentNtfCheckToken c tknId tkn
    _ -> throwError $ CMD PROHIBITED

deleteNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> m ()
deleteNtfToken' c deviceToken =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken} -> do
      when (deviceToken /= savedDeviceToken) . throwError $ CMD PROHIBITED
      deleteToken_ c tkn
      deleteNtfSubs c NSCSmpDelete
    _ -> throwError $ CMD PROHIBITED

getNtfToken' :: AgentMonad m => AgentClient -> m (DeviceToken, NtfTknStatus, NotificationsMode)
getNtfToken' c =
  withStore' c getSavedNtfToken >>= \case
    Just NtfToken {deviceToken, ntfTknStatus, ntfMode} -> pure (deviceToken, ntfTknStatus, ntfMode)
    _ -> throwError $ CMD PROHIBITED

getNtfTokenData' :: AgentMonad m => AgentClient -> m NtfToken
getNtfTokenData' c =
  withStore' c getSavedNtfToken >>= \case
    Just tkn -> pure tkn
    _ -> throwError $ CMD PROHIBITED

-- | Set connection notifications, in Reader monad
toggleConnectionNtfs' :: forall m. AgentMonad m => AgentClient -> ConnId -> Bool -> m ()
toggleConnectionNtfs' c connId enable = do
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection cData _ _ _ _) -> toggle cData
    SomeConn _ (RcvConnection cData _) -> toggle cData
    SomeConn _ (ContactConnection cData _) -> toggle cData
    _ -> throwError $ CONN SIMPLEX
  where
    toggle :: ConnData -> m ()
    toggle cData
      | enableNtfs cData == enable = pure ()
      | otherwise = do
        withStore' c $ \db -> setConnectionNtfs db connId enable
        ns <- asks ntfSupervisor
        let cmd = if enable then NSCCreate else NSCDelete
        atomically $ sendNtfSubCommand ns (connId, cmd)

deleteToken_ :: AgentMonad m => AgentClient -> NtfToken -> m ()
deleteToken_ c tkn@NtfToken {ntfTokenId, ntfTknStatus} = do
  ns <- asks ntfSupervisor
  forM_ ntfTokenId $ \tknId -> do
    let ntfTknAction = Just NTADelete
    withStore' c $ \db -> updateNtfToken db tkn ntfTknStatus ntfTknAction
    atomically $ nsUpdateToken ns tkn {ntfTknStatus, ntfTknAction}
    agentNtfDeleteToken c tknId tkn `catchError` \case
      NTF AUTH -> pure ()
      e -> throwError e
  withStore' c $ \db -> removeNtfToken db tkn
  atomically $ nsRemoveNtfToken ns

withToken :: AgentMonad m => AgentClient -> NtfToken -> Maybe (NtfTknStatus, NtfTknAction) -> (NtfTknStatus, Maybe NtfTknAction) -> m a -> m NtfTknStatus
withToken c tkn@NtfToken {deviceToken, ntfMode} from_ (toStatus, toAction_) f = do
  ns <- asks ntfSupervisor
  forM_ from_ $ \(status, action) -> do
    withStore' c $ \db -> updateNtfToken db tkn status (Just action)
    atomically $ nsUpdateToken ns tkn {ntfTknStatus = status, ntfTknAction = Just action}
  tryError f >>= \case
    Right _ -> do
      withStore' c $ \db -> updateNtfToken db tkn toStatus toAction_
      let updatedToken = tkn {ntfTknStatus = toStatus, ntfTknAction = toAction_}
      atomically $ nsUpdateToken ns updatedToken
      pure toStatus
    Left e@(NTF AUTH) -> do
      withStore' c $ \db -> removeNtfToken db tkn
      atomically $ nsRemoveNtfToken ns
      void $ registerNtfToken' c deviceToken ntfMode
      throwError e
    Left e -> throwError e

initializeNtfSubs :: AgentMonad m => AgentClient -> m ()
initializeNtfSubs c = sendNtfConnCommands c NSCCreate

deleteNtfSubs :: AgentMonad m => AgentClient -> NtfSupervisorCommand -> m ()
deleteNtfSubs c deleteCmd = do
  ns <- asks ntfSupervisor
  void . atomically . flushTBQueue $ ntfSubQ ns
  sendNtfConnCommands c deleteCmd

sendNtfConnCommands :: AgentMonad m => AgentClient -> NtfSupervisorCommand -> m ()
sendNtfConnCommands c cmd = do
  ns <- asks ntfSupervisor
  connIds <- atomically $ getSubscriptions c
  forM_ connIds $ \connId -> do
    withStore' c (\db -> getConnData db connId) >>= \case
      Just (ConnData {enableNtfs}, _) ->
        when enableNtfs . atomically $ writeTBQueue (ntfSubQ ns) (connId, cmd)
      _ ->
        atomically $ writeTBQueue (subQ c) ("", connId, ERR $ INTERNAL "no connection data")

-- TODO
-- There should probably be another function to cancel all subscriptions that would flush the queue first,
-- so that supervisor stops processing pending commands?
-- It is an optimization, but I am thinking how it would behave if a user were to flip on/off quickly several times.

setNtfServers' :: AgentMonad m => AgentClient -> [NtfServer] -> m ()
setNtfServers' c = atomically . writeTVar (ntfServers c)

activateAgent' :: AgentMonad m => AgentClient -> m ()
activateAgent' c = do
  atomically $ writeTVar (agentState c) ASActive
  mapM_ activate $ reverse agentOperations
  where
    activate opSel = atomically $ modifyTVar' (opSel c) $ \s -> s {opSuspended = False}

suspendAgent' :: AgentMonad m => AgentClient -> Int -> m ()
suspendAgent' c 0 = do
  atomically $ writeTVar (agentState c) ASSuspended
  mapM_ suspend agentOperations
  where
    suspend opSel = atomically $ modifyTVar' (opSel c) $ \s -> s {opSuspended = True}
suspendAgent' c@AgentClient {agentState = as} maxDelay = do
  state <-
    atomically $ do
      writeTVar as ASSuspending
      suspendOperation c AONtfNetwork $ pure ()
      suspendOperation c AORcvNetwork $
        suspendOperation c AOMsgDelivery $
          suspendSendingAndDatabase c
      readTVar as
  when (state == ASSuspending) . void . forkIO $ do
    threadDelay maxDelay
    -- liftIO $ putStrLn "suspendAgent after timeout"
    atomically . whenSuspending c $ do
      -- unsafeIOToSTM $ putStrLn $ "in timeout: suspendSendingAndDatabase"
      suspendSendingAndDatabase c

getAnySMPServer :: AgentMonad m => AgentClient -> m SMPServer
getAnySMPServer c = readTVarIO (smpServers c) >>= pickServer

pickServer :: AgentMonad m => NonEmpty SMPServer -> m SMPServer
pickServer = \case
  srv :| [] -> pure srv
  servers -> do
    gen <- asks randomServer
    atomically $ (servers L.!!) <$> stateTVar gen (randomR (0, L.length servers - 1))

getSMPServer :: AgentMonad m => AgentClient -> SMPServer -> m SMPServer
getSMPServer c (SMPServer host port _) = do
  srvs <- readTVarIO $ smpServers c
  case L.nonEmpty $ L.filter different srvs of
    Just srvs' -> pickServer srvs'
    _ -> pure $ L.head srvs
  where
    different (SMPServer host' port' _) = host /= host' || port /= port'

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
subscriber c@AgentClient {msgQ} = forever $ do
  t <- atomically $ readTBQueue msgQ
  agentOperationBracket c AORcvNetwork $
    withAgentLock c (runExceptT $ processSMPTransmission c t) >>= \case
      Left e -> liftIO $ print e
      Right _ -> return ()

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> ServerTransmission BrokerMsg -> m ()
processSMPTransmission c@AgentClient {smpClients, subQ} transmission@(srv, v, sessId, rId, cmd) = do
  (rq, SomeConn _ conn) <- withStore c $ \db -> getRcvConn db srv rId
  processSMP conn (connData conn) rq
  where
    processSMP :: Connection c -> ConnData -> RcvQueue -> m ()
    processSMP conn cData@ConnData {connId, duplexHandshake} rq@RcvQueue {e2ePrivKey, e2eDhSecret, status, currRcvQueue} =
      case cmd of
        SMP.MSG msg@SMP.RcvMessage {msgId = srvMsgId} -> handleNotifyAck $ do
          SMP.ClientRcvMsgBody {msgTs = srvTs, msgFlags, msgBody} <- decryptSMPMessage v rq msg
          clientMsg@SMP.ClientMsgEnvelope {cmHeader = SMP.PubHeader phVer e2ePubKey_} <-
            parseMessage msgBody
          clientVRange <- asks $ smpClientVRange . config
          unless (phVer `isCompatible` clientVRange) . throwError $ AGENT A_VERSION
          case (e2eDhSecret, e2ePubKey_) of
            (Nothing, Just e2ePubKey) -> do
              unless (currRcvQueue) . throwError $ INTERNAL "can only be sent to the current queue"
              let e2eDh = C.dh' e2ePubKey e2ePrivKey
              decryptClientMessage e2eDh clientMsg >>= \case
                (SMP.PHConfirmation senderKey, AgentConfirmation {e2eEncryption, encConnInfo, agentVersion}) ->
                  smpConfirmation senderKey e2ePubKey e2eEncryption encConnInfo phVer agentVersion >> ack
                (SMP.PHEmpty, AgentInvitation {connReq, connInfo}) ->
                  smpInvitation connReq connInfo >> ack
                _ -> prohibited >> ack
            (Just e2eDh, Nothing) -> do
              decryptClientMessage e2eDh clientMsg >>= \case
                (SMP.PHEmpty, AgentMsgEnvelope _ encAgentMsg) ->
                  tryError agentClientMsg >>= \case
                    Right (Just (msgId, msgMeta, aMessage)) -> case aMessage of
                      HELLO -> helloMsg >> ackDelete msgId
                      REPLY cReq -> replyMsg cReq >> ackDelete msgId
                      -- note that there is no ACK sent for A_MSG, it is sent with agent's user ACK command
                      A_MSG body
                        | currRcvQueue -> do
                          logServer "<--" c srv rId "MSG <MSG>"
                          notify $ MSG msgMeta msgFlags body
                        | otherwise -> atomically $ TM.alter addTransmission (srv, rId) (nextRcvQueueMsgs c)
                        where
                          addTransmission = Just . maybe [transmission] (transmission :)
                      QNEW currAddr nextQUri -> rqNewMsg currAddr nextQUri >> ackDelete msgId
                      QKEYS sKey nextQInfo -> rqKeys sKey nextQInfo $ ackDelete msgId
                      QREADY addr -> rqReady addr >> ackDelete msgId
                      QTEST -> rqTest >> ackDelete msgId
                      QSWITCH addr -> rqSwitch addr >> ackDelete msgId
                      QHELLO -> rqHello $ ackDelete msgId
                    Right _ -> prohibited >> ack
                    Left e@(AGENT A_DUPLICATE) -> do
                      withStore' c (\db -> getLastMsg db connId srvMsgId) >>= \case
                        Just RcvMsg {internalId, msgMeta, msgBody = agentMsgBody, userAck}
                          | userAck -> do
                            ack
                            withStore' c $ \db -> deleteMsg db connId internalId
                          | otherwise -> do
                            liftEither (parse smpP (AGENT A_MESSAGE) agentMsgBody) >>= \case
                              AgentMessage _ (A_MSG body)
                                | currRcvQueue -> do
                                  logServer "<--" c srv rId "MSG <MSG>"
                                  notify $ MSG msgMeta msgFlags body
                                | otherwise -> atomically $ TM.alter addTransmission (srv, rId) (nextRcvQueueMsgs c)
                                where
                                  addTransmission = Just . maybe [transmission] prependIfDifferent
                                  prependIfDifferent = \case
                                    [] -> [transmission]
                                    ts@((_, _, _, _, cmd') : _)
                                      | cmd == cmd' -> ts
                                      | otherwise -> transmission : ts
                              _ -> pure ()
                        _ -> throwError e
                    Left e -> throwError e
                  where
                    agentClientMsg :: m (Maybe (InternalId, MsgMeta, AMessage))
                    agentClientMsg = withStore c $ \db -> runExceptT $ do
                      agentMsgBody <- agentRatchetDecrypt db connId encAgentMsg
                      liftEither (parse smpP (SEAgentError $ AGENT A_MESSAGE) agentMsgBody) >>= \case
                        agentMsg@(AgentMessage APrivHeader {sndMsgId, prevMsgHash} aMessage) -> do
                          let msgType = agentMessageType agentMsg
                              internalHash = C.sha256Hash agentMsgBody
                          internalTs <- liftIO getCurrentTime
                          (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- liftIO $ updateRcvIds db connId
                          let integrity = checkMsgIntegrity prevExtSndId sndMsgId prevRcvMsgHash prevMsgHash
                              recipient = (unId internalId, internalTs)
                              broker = (srvMsgId, systemToUTCTime srvTs)
                              msgMeta = MsgMeta {integrity, recipient, broker, sndMsgId}
                              rcvMsg = RcvMsgData {msgMeta, msgType, msgFlags, msgBody = agentMsgBody, internalRcvId, internalHash, externalPrevSndHash = prevMsgHash}
                          liftIO $ createRcvMsg db connId rcvMsg
                          pure $ Just (internalId, msgMeta, aMessage)
                        _ -> pure Nothing
                _ -> prohibited >> ack
            _ -> prohibited >> ack
          where
            ack :: m ()
            ack =
              sendAck c rq srvMsgId `catchError` \case
                SMP SMP.NO_MSG -> pure ()
                e -> throwError e
            ackDelete :: InternalId -> m ()
            ackDelete msgId = ack >> withStore' c (\db -> deleteMsg db connId msgId)
            handleNotifyAck :: m () -> m ()
            handleNotifyAck m = m `catchError` \e -> notify (ERR e) >> ack
        SMP.END ->
          atomically (TM.lookup srv smpClients $>>= tryReadTMVar >>= processEND)
            >>= logServer "<--" c srv rId
          where
            processEND = \case
              Just (Right clnt)
                | sessId == sessionId clnt -> do
                  removeSubscription c connId
                  writeTBQueue subQ ("", connId, END)
                  pure "END"
                | otherwise -> ignored
              _ -> ignored
            ignored = pure "END from disconnected client - ignored"
        SMP.LEN 0 -> do
          -- load nextRq
          -- currRcvQueueDrained c rq nextRq
          pure ()
        _ -> do
          logServer "<--" c srv rId $ "unexpected: " <> bshow cmd
          notify . ERR $ BROKER UNEXPECTED
      where
        notify :: ACommand 'Agent -> m ()
        notify msg = atomically $ writeTBQueue subQ ("", connId, msg)

        prohibited :: m ()
        prohibited = notify . ERR $ AGENT A_PROHIBITED

        decryptClientMessage :: C.DhSecretX25519 -> SMP.ClientMsgEnvelope -> m (SMP.PrivHeader, AgentMsgEnvelope)
        decryptClientMessage e2eDh SMP.ClientMsgEnvelope {cmNonce, cmEncBody} = do
          clientMsg <- agentCbDecrypt e2eDh cmNonce cmEncBody
          SMP.ClientMessage privHeader clientBody <- parseMessage clientMsg
          agentEnvelope <- parseMessage clientBody
          -- Version check is removed here, because when connecting via v1 contact address the agent still sends v2 message,
          -- to allow duplexHandshake mode, in case the receiving agent was updated to v2 after the address was created.
          -- aVRange <- asks $ smpAgentVRange . config
          -- if agentVersion agentEnvelope `isCompatible` aVRange
          --   then pure (privHeader, agentEnvelope)
          --   else throwError $ AGENT A_VERSION
          pure (privHeader, agentEnvelope)

        parseMessage :: Encoding a => ByteString -> m a
        parseMessage = liftEither . parse smpP (AGENT A_MESSAGE)

        smpConfirmation :: C.APublicVerifyKey -> C.PublicKeyX25519 -> Maybe (CR.E2ERatchetParams 'C.X448) -> ByteString -> Version -> Version -> m ()
        smpConfirmation senderKey e2ePubKey e2eEncryption encConnInfo smpClientVersion agentVersion = do
          logServer "<--" c srv rId "MSG <CONF>"
          AgentConfig {smpAgentVRange, smpClientVRange} <- asks config
          unless
            (agentVersion `isCompatible` smpAgentVRange && smpClientVersion `isCompatible` smpClientVRange)
            (throwError $ AGENT A_VERSION)
          case status of
            New -> case (conn, e2eEncryption) of
              -- party initiating connection
              (RcvConnection {}, Just e2eSndParams) -> do
                (pk1, rcDHRs) <- withStore c $ (`getRatchetX3dhKeys` connId)
                let rc = CR.initRcvRatchet rcDHRs $ CR.x3dhRcv pk1 rcDHRs e2eSndParams
                (agentMsgBody_, rc', skipped) <- liftError cryptoError $ CR.rcDecrypt rc M.empty encConnInfo
                case (agentMsgBody_, skipped) of
                  (Right agentMsgBody, CR.SMDNoChange) ->
                    parseMessage agentMsgBody >>= \case
                      AgentConnInfo connInfo ->
                        processConf connInfo SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues = [], smpClientVersion} False
                      AgentConnInfoReply smpQueues connInfo ->
                        processConf connInfo SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues = L.toList smpQueues, smpClientVersion} True
                      _ -> prohibited
                    where
                      processConf connInfo senderConf duplexHS = do
                        let newConfirmation = NewConfirmation {connId, senderConf, ratchetState = rc'}
                        g <- asks idsDrg
                        confId <- withStore c $ \db -> do
                          setHandshakeVersion db connId agentVersion duplexHS
                          createConfirmation db g newConfirmation
                        let srvs = map queueServer $ smpReplyQueues senderConf
                        notify $ CONF confId srvs connInfo
                      queueServer (SMPQueueInfo _ SMPQueueAddress {smpServer}) = smpServer
                  _ -> prohibited
              -- party accepting connection
              (DuplexConnection _ _ sq _ _, Nothing) -> do
                withStore c (\db -> runExceptT $ agentRatchetDecrypt db connId encConnInfo) >>= parseMessage >>= \case
                  AgentConnInfo connInfo -> do
                    notify $ INFO connInfo
                    processConfirmation c rq $ SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues = [], smpClientVersion}
                    when (duplexHandshake == Just True) $ enqueueDuplexHello sq
                  _ -> prohibited
              _ -> prohibited
            _ -> prohibited

        helloMsg :: m ()
        helloMsg = do
          unless currRcvQueue . throwError $ INTERNAL "can only be sent to the current queue"
          logServer "<--" c srv rId "MSG <HELLO>"
          case status of
            Active -> prohibited
            _ -> do
              withStore' c $ \db -> setRcvQueueStatus db rq Active
              case conn of
                DuplexConnection _ _ sq@SndQueue {status = sndStatus} _ _
                  -- `sndStatus == Active` when HELLO was previously sent, and this is the reply HELLO
                  -- this branch is executed by the accepting party in duplexHandshake mode (v2)
                  -- and by the initiating party in v1
                  -- Also see comment where HELLO is sent.
                  | sndStatus == Active -> atomically $ writeTBQueue subQ ("", connId, CON)
                  | duplexHandshake == Just True -> enqueueDuplexHello sq
                  | otherwise -> pure ()
                _ -> pure ()

        enqueueDuplexHello :: SndQueue -> m ()
        enqueueDuplexHello sq = void $ enqueueMessage c cData sq SMP.MsgFlags {notification = True} HELLO

        replyMsg :: L.NonEmpty SMPQueueInfo -> m ()
        replyMsg smpQueues = do
          unless currRcvQueue . throwError $ INTERNAL "can only be sent to the current queue"
          logServer "<--" c srv rId "MSG <REPLY>"
          case duplexHandshake of
            Just True -> prohibited
            _ -> case conn of
              RcvConnection {} -> do
                AcceptedConfirmation {ownConnInfo} <- withStore c (`getAcceptedConfirmation` connId)
                connectReplyQueues c cData ownConnInfo smpQueues `catchError` (notify . ERR)
              _ -> prohibited

        -- processed by queue sender
        rqNewMsg :: (SMPServer, SMP.SenderId) -> SMPQueueUri -> m ()
        rqNewMsg (smpServer, senderId) nextQUri = case conn of
          DuplexConnection _ _ sq@SndQueue {server, sndId} nextRq_ _ -> do
            liftIO $ print $ "rqNewMsg " <> show (SMP.port server) <> " " <> show (currSndQueue sq)
            unless (smpServer == server && senderId == sndId) . throwError $ INTERNAL "incorrect queue address"
            clientVRange <- asks $ smpClientVRange . config
            case (nextQUri `compatibleVersion` clientVRange) of
              Just qInfo@(Compatible nextQInfo) -> do
                sq'@SndQueue {sndPublicKey, e2ePubKey, server = srv'} <- newSndQueue qInfo False
                withStore' c $ \db -> dbCreateNextSndQueue db connId sq sq'
                liftIO $ print $ "rqNewMsg: next SndQueue " <> show (SMP.port srv') <> " " <> show (currSndQueue sq')
                case (sndPublicKey, e2ePubKey) of
                  (Just nextSenderKey, Just dhPublicKey) -> do
                    let qAddr = (queueAddress (nextQInfo :: SMPQueueInfo)) {dhPublicKey}
                        nextQueueInfo = (nextQInfo :: SMPQueueInfo) {queueAddress = qAddr}
                    void . enqueueMessage c cData sq SMP.noMsgFlags $ QKEYS {nextSenderKey, nextQueueInfo}
                    let conn' = DuplexConnection cData rq sq nextRq_ (Just sq')
                    notify . SWITCH SPStarted $ connectionStats conn'
                  _ -> throwError $ INTERNAL "absent sender keys"
              _ -> throwError $ AGENT A_VERSION
          _ -> throwError $ INTERNAL "message can only be sent to duplex connection"

        -- processed by queue recipient
        rqKeys :: SndPublicVerifyKey -> SMPQueueInfo -> m () -> m ()
        rqKeys senderKey qInfo@(SMPQueueInfo clntVer' SMPQueueAddress {smpServer, senderId, dhPublicKey}) ackDelete = do
          unless currRcvQueue . throwError $ INTERNAL "message can only be sent to current queue"
          liftIO $ print $ "rqKeys " <> show (SMP.port srv) <> " " <> show currRcvQueue
          case conn of
            DuplexConnection _ _ sq nextRq_ _ -> do
              clientVRange <- asks $ smpClientVRange . config
              unless (qInfo `isCompatible` clientVRange) . throwError $ AGENT A_VERSION
              case nextRq_ of
                Just rq'@RcvQueue {server, sndId, e2ePrivKey = dhPrivKey, smpClientVersion = clntVer, currRcvQueue = curr'} -> do
                  liftIO $ print $ "rqKeys next RcvQueue " <> show (SMP.port server) <> " " <> show curr'
                  unless (smpServer == server && senderId == sndId) . throwError $ INTERNAL "incorrect queue address"
                  let dhSecret = C.dh' dhPublicKey dhPrivKey
                  withStore' c $ \db -> do
                    setRcvQueueConfirmedE2E db rq' senderKey dhSecret $ min clntVer clntVer'
                    setRcvQueueAction db rq $ Just RQASecureNextQueue
                  ackDelete
                  secureNextRcvQueue c cData rq sq rq'
                _ -> throwError $ INTERNAL "message can only be sent during rotation"
            _ -> throwError $ INTERNAL "message can only be sent to duplex connection"

        -- processed by queue sender
        rqReady :: (SMPServer, SMP.SenderId) -> m ()
        rqReady (smpServer, senderId) = case conn of
          DuplexConnection _ _ sq@SndQueue {server = srv1} _ nextSq_ -> do
            liftIO $ print $ "rqReady " <> show (SMP.port srv1) <> " " <> show (currSndQueue sq)
            case nextSq_ of
              Just sq'@SndQueue {server, sndId, currSndQueue = curr'} -> do
                liftIO $ print $ "rqReady next SndQueue " <> show (SMP.port server) <> " " <> show curr'
                unless (smpServer == server && senderId == sndId) . throwError $ INTERNAL "incorrect queue address"
                void $ enqueueMessage c cData sq' SMP.noMsgFlags QTEST
              _ -> throwError $ INTERNAL "message can only be sent during rotation"
          _ -> throwError $ INTERNAL "message can only be sent to duplex connection"

        -- processed by queue recipient, received from the new queue
        rqTest :: m ()
        rqTest = do
          liftIO $ print $ "rqTest " <> show (SMP.port srv) <> " " <> show currRcvQueue
          when currRcvQueue . throwError $ INTERNAL "2: message can only be sent to the next queue"
          case conn of
            DuplexConnection _ _ sq _ _ -> do
              let RcvQueue {server, sndId} = rq
              void . enqueueMessage c cData sq SMP.noMsgFlags $ QSWITCH (server, sndId)
            _ -> throwError $ INTERNAL "message can only be sent to duplex connection"

        -- processed by queue sender
        rqSwitch :: (SMPServer, SMP.SenderId) -> m ()
        rqSwitch (smpServer, senderId) = case conn of
          DuplexConnection _ _ sq@SndQueue {server, sndId} nextRq_ nextSq_ -> case nextSq_ of
            Just sq'@SndQueue {server = server', sndId = sndId'} -> do
              unless (smpServer == server' && senderId == sndId') . throwError $ INTERNAL "incorrect queue address"
              let qKey = (server, sndId)
                  qKey' = (server', sndId')
              ok <-
                switchQueues qKey qKey' `catchError` \e -> do
                  atomically (switchDeliveries qKey' qKey)
                  throwError e
              unless ok $ throwError $ INTERNAL "switching snd queue failed in STM"
              void $ enqueueMessage c cData sq' SMP.noMsgFlags QHELLO
              let conn' = DuplexConnection cData rq sq' nextRq_ Nothing
              notify . SWITCH SPCompleted $ connectionStats conn'
              where
                switchQueues :: MsgDeliveryKey -> MsgDeliveryKey -> m Bool
                switchQueues k k' = withStore' c $ \db -> do
                  ok <- atomically $ (switchDeliveries k k' $> True) `orElse` pure False
                  when ok $ switchCurrSndQueue db sq sq'
                  pure ok
                switchDeliveries :: MsgDeliveryKey -> MsgDeliveryKey -> STM ()
                switchDeliveries k k' = do
                  switchDelivery smpQueueMsgQueues k k'
                  switchDelivery smpQueueMsgDeliveries k k'
                switchDelivery :: (AgentClient -> TMap MsgDeliveryKey a) -> MsgDeliveryKey -> MsgDeliveryKey -> STM ()
                switchDelivery sel k k' =
                  TM.lookupDelete k (sel c) >>= \case
                    Just d -> TM.insert k' d (sel c)
                    _ -> retry
            _ -> throwError $ INTERNAL "message can only be sent during rotation"
          _ -> throwError $ INTERNAL "message can only be sent to duplex connection"

        -- processed by queue recipient, received from the new queue
        rqHello :: m () -> m ()
        rqHello ackDelete = do
          when currRcvQueue . throwError $ INTERNAL "1: message can only be sent to the next queue"
          case conn of
            DuplexConnection _ currRq sq _ _ -> do
              withStore' c $ \db -> do
                setRcvQueueStatus db rq Active
                setRcvQueueAction db currRq $ Just RQASuspendCurrQueue
              ackDelete
              suspendCurrRcvQueue c cData currRq sq rq
            _ -> throwError $ INTERNAL "message can only be sent to duplex connection"

        smpInvitation :: ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
        smpInvitation connReq@(CRInvitationUri crData _) cInfo = do
          logServer "<--" c srv rId "MSG <KEY>"
          case conn of
            ContactConnection {} -> do
              g <- asks idsDrg
              let newInv = NewInvitation {contactConnId = connId, connReq, recipientConnInfo = cInfo}
              invId <- withStore c $ \db -> createInvitation db g newInv
              let srvs = L.map queueServer $ crSmpQueues crData
              notify $ REQ invId srvs cInfo
            _ -> prohibited
          where
            queueServer (SMPQueueUri _ SMPQueueAddress {smpServer}) = smpServer

        checkMsgIntegrity :: PrevExternalSndId -> ExternalSndId -> PrevRcvMsgHash -> ByteString -> MsgIntegrity
        checkMsgIntegrity prevExtSndId extSndId internalPrevMsgHash receivedPrevMsgHash
          | extSndId == prevExtSndId + 1 && internalPrevMsgHash == receivedPrevMsgHash = MsgOk
          | extSndId < prevExtSndId = MsgError $ MsgBadId extSndId
          | extSndId == prevExtSndId = MsgError MsgDuplicate -- ? deduplicate
          | extSndId > prevExtSndId + 1 = MsgError $ MsgSkipped (prevExtSndId + 1) (extSndId - 1)
          | internalPrevMsgHash /= receivedPrevMsgHash = MsgError MsgBadHash
          | otherwise = MsgError MsgDuplicate -- this case is not possible

connectReplyQueues :: AgentMonad m => AgentClient -> ConnData -> ConnInfo -> L.NonEmpty SMPQueueInfo -> m ()
connectReplyQueues c cData@ConnData {connId} ownConnInfo (qInfo :| _) = do
  clientVRange <- asks $ smpClientVRange . config
  case qInfo `proveCompatible` clientVRange of
    Nothing -> throwError $ AGENT A_VERSION
    Just qInfo' -> do
      sq <- newSndQueue qInfo' True
      withStore c $ \db -> upgradeRcvConnToDuplex db connId sq
      enqueueConfirmation c cData sq ownConnInfo Nothing

confirmQueue :: forall m. AgentMonad m => Compatible Version -> AgentClient -> ConnData -> SndQueue -> ConnInfo -> Maybe (CR.E2ERatchetParams 'C.X448) -> m ()
confirmQueue (Compatible agentVersion) c cData@ConnData {connId} sq connInfo e2eEncryption = do
  aMessage <- mkAgentMessage agentVersion
  msg <- mkConfirmation aMessage
  sendConfirmation c sq msg
  withStore' c $ \db -> setSndQueueStatus db sq Confirmed
  where
    mkConfirmation :: AgentMessage -> m MsgBody
    mkConfirmation aMessage = withStore c $ \db -> runExceptT $ do
      void . liftIO $ updateSndIds db connId
      encConnInfo <- agentRatchetEncrypt db connId (smpEncode aMessage) e2eEncConnInfoLength
      pure . smpEncode $ AgentConfirmation {agentVersion, e2eEncryption, encConnInfo}
    mkAgentMessage :: Version -> m AgentMessage
    mkAgentMessage 1 = pure $ AgentConnInfo connInfo
    mkAgentMessage _ = do
      qInfo <- createReplyQueue c cData sq
      pure $ AgentConnInfoReply (qInfo :| []) connInfo

enqueueConfirmation :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> ConnInfo -> Maybe (CR.E2ERatchetParams 'C.X448) -> m ()
enqueueConfirmation c cData@ConnData {connId, connAgentVersion} sq connInfo e2eEncryption = do
  resumeMsgDelivery c cData sq
  msgId <- storeConfirmation
  queuePendingMsgs c sq [msgId]
  where
    storeConfirmation :: m InternalId
    storeConfirmation = withStore c $ \db -> runExceptT $ do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
      let agentMsg = AgentConnInfo connInfo
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      encConnInfo <- agentRatchetEncrypt db connId agentMsgStr e2eEncConnInfoLength
      let msgBody = smpEncode $ AgentConfirmation {agentVersion = connAgentVersion, e2eEncryption, encConnInfo}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgBody, msgFlags = SMP.MsgFlags {notification = True}, internalHash, prevMsgHash}
      liftIO $ createSndMsg db connId msgData
      pure internalId

-- encoded AgentMessage -> encoded EncAgentMessage
agentRatchetEncrypt :: DB.Connection -> ConnId -> ByteString -> Int -> ExceptT StoreError IO ByteString
agentRatchetEncrypt db connId msg paddedLen = do
  rc <- ExceptT $ getRatchet db connId
  (encMsg, rc') <- liftE (SEAgentError . cryptoError) $ CR.rcEncrypt rc paddedLen msg
  liftIO $ updateRatchet db connId rc' CR.SMDNoChange
  pure encMsg

-- encoded EncAgentMessage -> encoded AgentMessage
agentRatchetDecrypt :: DB.Connection -> ConnId -> ByteString -> ExceptT StoreError IO ByteString
agentRatchetDecrypt db connId encAgentMsg = do
  rc <- ExceptT $ getRatchet db connId
  skipped <- liftIO $ getSkippedMsgKeys db connId
  (agentMsgBody_, rc', skippedDiff) <- liftE (SEAgentError . cryptoError) $ CR.rcDecrypt rc skipped encAgentMsg
  liftIO $ updateRatchet db connId rc' skippedDiff
  liftEither $ first (SEAgentError . cryptoError) agentMsgBody_

newSndQueue :: (MonadUnliftIO m, MonadReader Env m) => Compatible SMPQueueInfo -> Bool -> m SndQueue
newSndQueue qInfo current =
  asks (cmdSignAlg . config) >>= \case
    C.SignAlg a -> newSndQueue_ a qInfo current

newSndQueue_ ::
  (C.SignatureAlgorithm a, C.AlgorithmI a, MonadUnliftIO m) =>
  C.SAlgorithm a ->
  Compatible SMPQueueInfo ->
  Bool ->
  m SndQueue
newSndQueue_ a (Compatible (SMPQueueInfo smpClientVersion SMPQueueAddress {smpServer, senderId, dhPublicKey = rcvE2ePubDhKey})) current = do
  -- this function assumes clientVersion is compatible - it was tested before
  (sndPublicKey, sndPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (e2ePubKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  createdAt <- liftIO getCurrentTime
  pure
    SndQueue
      { server = smpServer,
        sndId = senderId,
        sndPublicKey = Just sndPublicKey,
        sndPrivateKey,
        e2eDhSecret = C.dh' rcvE2ePubDhKey e2ePrivKey,
        e2ePubKey = Just e2ePubKey,
        status = New,
        currSndQueue = current,
        dbNextSndQueueId = Nothing,
        sndQueueAction = Nothing,
        smpClientVersion,
        createdAt,
        updatedAt = createdAt
      }
