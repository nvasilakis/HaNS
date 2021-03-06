{-# LANGUAGE EmptyDataDecls #-}

module Hans.Layer.Tcp.WaitBuffer (
    -- * Delayed work
    Wakeup
  , tryAgain
  , abort

    -- * Directions
  , Incoming, Outgoing

    -- * Directed Buffers
  , Buffer
  , emptyBuffer
  , shutdownWaiting
  , availableBytes
  , flushWaiting

    -- ** Application Side
  , writeBytes
  , readBytes

    -- ** Kernel Side
  , takeBytes
  , putBytes
  ) where

import Control.Monad (guard)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString.Lazy as L
import qualified Data.Foldable as F
import qualified Data.Sequence as Seq


-- Chunk Buffering -------------------------------------------------------------

-- | The boolean parameter indicates whether or not the continuation is being
-- called in the event of a shutdown, or if the computation should be re-run,
-- allowing for more data to flow.
type Wakeup = Bool -> IO ()

-- | Indicate that the action should be retried.
tryAgain :: Wakeup -> IO ()
tryAgain f = f True

-- | Indicate that the action should not be retried.
abort :: Wakeup -> IO ()
abort f = f False

-- | Incoming data.
data Incoming

-- | Outgoing data.
data Outgoing

-- | Data Buffers, in a direction.
data Buffer d = Buffer
  { bufBytes     :: L.ByteString
  , bufWaiting   :: Seq.Seq Wakeup
  , bufSize      :: !Int64
  , bufAvailable :: !Int64
  }

-- | An empty buffer, with a limit.
emptyBuffer :: Int64 -> Buffer d
emptyBuffer size = Buffer
  { bufBytes     = L.empty
  , bufWaiting   = Seq.empty
  , bufSize      = size
  , bufAvailable = size
  }

-- | External interface.
availableBytes :: Buffer d -> Int64
availableBytes  = bufAvailable

-- | Flush the queue of blocked processes.
flushWaiting :: Buffer d -> Buffer d
flushWaiting buf = buf { bufWaiting = Seq.empty }

-- | Queue a wakeup action into a buffer.
queueWaiting :: Wakeup -> Buffer d -> Buffer d
queueWaiting wakeup buf = buf { bufWaiting = bufWaiting buf Seq.|> wakeup }

-- | Queue bytes into a buffer that has some available size.
queueBytes :: L.ByteString -> Buffer d -> (Maybe Int64, Buffer d)
queueBytes bytes buf
  | bufAvailable buf <= 0 = (Nothing,buf)
  | otherwise             = (Just qlen, buf')
  where
  queued = L.take (bufAvailable buf) bytes
  qlen   = L.length queued
  buf'   = buf
    { bufBytes     = bufBytes buf `L.append` queued
    , bufAvailable = bufAvailable buf - qlen
    }

-- | Take bytes off of a buffer, if there are any available.
removeBytes :: Int64 -> Buffer d -> Maybe (L.ByteString, Buffer d)
removeBytes len buf = do
  guard (not (L.null (bufBytes buf)))
  let (bytes,rest) = L.splitAt len (bufBytes buf)
      buf' = buf
        { bufBytes     = rest
        , bufAvailable = bufAvailable buf + L.length bytes
        }
  return (bytes,buf')

-- | Run all waiting continuations with a parameter of False, 
shutdownWaiting :: Buffer d -> (IO (), Buffer d)
shutdownWaiting buf = (m,buf { bufWaiting = Seq.empty })
  where
  m = F.mapM_ abort (bufWaiting buf)


-- Sending Buffer --------------------------------------------------------------

-- | Queue bytes in an outgoing buffer.  When the number of bytes written is
-- @Nothing@, the wakeup action has been queued.
writeBytes :: L.ByteString -> Wakeup -> Buffer Outgoing
           -> (Maybe Int64,Buffer Outgoing)
writeBytes bytes wakeup buf = case queueBytes bytes buf of
  (Nothing,buf') -> (Nothing,queueWaiting wakeup buf')
  res            -> res

-- | Take bytes off of a sending queue, making room new data.
takeBytes :: Int64 -> Buffer Outgoing
          -> Maybe (Maybe Wakeup,L.ByteString,Buffer Outgoing)
takeBytes len buf = do
  (bytes,buf') <- removeBytes len buf
  case Seq.viewl (bufWaiting buf') of
    Seq.EmptyL  -> return (Nothing, bytes, buf')
    w Seq.:< ws -> return (Just w, bytes, buf' { bufWaiting = ws })


-- Receiving Buffer ------------------------------------------------------------

-- | Read bytes from an incoming buffer, queueing if there are no bytes to read.
readBytes :: Int64 -> Wakeup -> Buffer Incoming
          -> (Maybe L.ByteString, Buffer Incoming)
readBytes len wakeup buf = fromMaybe (Nothing,waitBuf) $ do
  (bytes,buf') <- removeBytes len buf
  return (Just bytes,buf')
  where
  waitBuf = queueWaiting wakeup buf

-- | Place bytes on the incoming buffer, provided that there is enough space for
-- all of the bytes.
putBytes :: L.ByteString -> Buffer Incoming
         -> Maybe (Maybe Wakeup,Buffer Incoming)
putBytes bytes buf = do
  let needed = L.length bytes + L.length (bufBytes buf)
  guard (needed < bufSize buf)
  let buf' = buf { bufBytes = bufBytes buf `L.append` bytes }
  case Seq.viewl (bufWaiting buf') of
    Seq.EmptyL  -> return (Nothing, buf')
    w Seq.:< ws -> return (Just w, buf' { bufWaiting = ws })
