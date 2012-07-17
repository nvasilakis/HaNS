module Hans.Layer.Tcp.Monad where

import Hans.Channel
import Hans.Layer
import Hans.Layer.IP4
import Hans.Layer.Timer

import MonadLib (get)


-- TCP Monad -------------------------------------------------------------------

type TcpHandle = Channel (Tcp ())

type Thread = IO ()

type Tcp = Layer (TcpState Thread)

data TcpState t = TcpState
  { tcpSelf   :: TcpHandle
  , tcpIP4    :: IP4Handle
  , tcpTimers :: TimerHandle
  }

emptyTcpState :: TcpHandle -> IP4Handle -> TimerHandle -> TcpState t
emptyTcpState tcp ip4 timer = TcpState
  { tcpSelf   = tcp
  , tcpIP4    = ip4
  , tcpTimers = timer
  }

-- | The handle to this layer.
self :: Tcp TcpHandle
self  = tcpSelf `fmap` get

-- | Get the handle to the IP4 layer.
ip4Handle :: Tcp IP4Handle
ip4Handle  = tcpIP4 `fmap` get

-- | Get the handle to the Timer layer.
timerHandle :: Tcp TimerHandle
timerHandle  = tcpTimers `fmap` get
