{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Hans.NetworkStack (
    module Hans.NetworkStack

    -- * Re-exported Types
  , UdpPort
  , TcpPort

    -- * Sockets
  , Tcp.Socket()

    -- ** Socket Functions
  , Tcp.sockRemoteHost
  , Tcp.sockRemotePort
  , Tcp.sockLocalPort
  , Tcp.accept
  , Tcp.close
  , Tcp.sendBytes
  , Tcp.recvBytes

    -- ** Socket Exceptions
  , Tcp.AcceptError(..)
  , Tcp.CloseError(..)
  , Tcp.ConnectError(..)
  ) where

import Hans.Address (getMaskComponents)
import Hans.Address.IP4 (IP4Mask,IP4)
import Hans.Address.Mac (Mac)
import Hans.Channel (newChannel)
import Hans.Message.Ip4 (IP4Protocol,IP4Header)
import Hans.Message.Tcp (TcpPort)
import Hans.Message.Udp (UdpPort)
import qualified Hans.Layer.Arp as Arp
import qualified Hans.Layer.Ethernet as Eth
import qualified Hans.Layer.Icmp4 as Icmp4
import qualified Hans.Layer.IP4 as IP4
import qualified Hans.Layer.Tcp as Tcp
import qualified Hans.Layer.Tcp.Socket as Tcp
import qualified Hans.Layer.Timer as Timer
import qualified Hans.Layer.Udp as Udp

import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L


-- Generic Network Stack -------------------------------------------------------

-- | An example implementation of the whole network stack.
data NetworkStack = NetworkStack
  { nsArp       :: Arp.ArpHandle
  , nsEthernet  :: Eth.EthernetHandle
  , nsIp4       :: IP4.IP4Handle
  , nsIcmp4     :: Icmp4.Icmp4Handle
  , nsTimers    :: Timer.TimerHandle
  , nsUdp       :: Udp.UdpHandle
  , nsTcp       :: Tcp.TcpHandle
  }

instance HasArp      NetworkStack where arpHandle      = nsArp
instance HasEthernet NetworkStack where ethernetHandle = nsEthernet
instance HasIP4      NetworkStack where ip4Handle      = nsIp4
instance HasIcmp4    NetworkStack where icmp4Handle    = nsIcmp4
instance HasTimer    NetworkStack where timerHandle    = nsTimers
instance HasTcp      NetworkStack where tcpHandle      = nsTcp
instance HasUdp      NetworkStack where udpHandle      = nsUdp

newNetworkStack :: IO NetworkStack
newNetworkStack  = do
  eth  <- newChannel
  arp  <- newChannel
  ip4  <- newChannel
  icmp <- newChannel
  th   <- newChannel
  udp  <- newChannel
  tcp  <- newChannel

  let ns = NetworkStack
        { nsArp     = arp
        , nsEthernet= eth
        , nsIp4     = ip4
        , nsIcmp4   = icmp
        , nsTimers  = th
        , nsUdp     = udp
        , nsTcp     = tcp
        }

  startTimerLayer    ns
  startEthernetLayer ns
  startArpLayer      ns
  startIcmp4Layer    ns
  startIP4Layer      ns
  startUdpLayer      ns
  startTcpLayer      ns

  return ns



-- Ethernet Layer Interface ----------------------------------------------------

class HasEthernet stack where
  ethernetHandle :: stack -> Eth.EthernetHandle

instance HasEthernet Eth.EthernetHandle where ethernetHandle = id

-- | Start the ethernet layer in a network stack.
startEthernetLayer :: HasEthernet stack => stack -> IO ()
startEthernetLayer stack =
  Eth.runEthernetLayer (ethernetHandle stack)

-- | Add an ethernet device to the ethernet layer.
addDevice :: HasEthernet stack => stack -> Mac -> Eth.Tx -> Eth.Rx -> IO ()
addDevice stack = Eth.addEthernetDevice (ethernetHandle stack)

-- | Remove a device from the ethernet layer.
removeDevice :: HasEthernet stack => stack -> Mac -> IO ()
removeDevice stack = Eth.removeEthernetDevice (ethernetHandle stack)

-- | Bring an ethernet device in the ethernet layer up.
deviceUp :: HasEthernet stack => stack -> Mac -> IO ()
deviceUp stack = Eth.startEthernetDevice (ethernetHandle stack)

-- | Bring an ethernet device in the ethernet layer down.
deviceDown :: HasEthernet stack => stack -> Mac -> IO ()
deviceDown stack = Eth.stopEthernetDevice (ethernetHandle stack)


-- Arp Layer Interface ---------------------------------------------------------

class HasArp stack where
  arpHandle :: stack -> Arp.ArpHandle

instance HasArp Arp.ArpHandle where arpHandle = id

-- | Start the arp layer in a network stack.
startArpLayer :: (HasEthernet stack, HasTimer stack, HasArp stack)
              => stack -> IO ()
startArpLayer stack =
  Arp.runArpLayer (arpHandle stack) (ethernetHandle stack) (timerHandle stack)


-- Icmp4 Layer Interface -------------------------------------------------------

class HasIcmp4 stack where
  icmp4Handle :: stack -> Icmp4.Icmp4Handle

instance HasIcmp4 Icmp4.Icmp4Handle where icmp4Handle = id

-- | Start the icmp4 layer in a network stack..
startIcmp4Layer :: (HasIcmp4 stack, HasIP4 stack) => stack -> IO ()
startIcmp4Layer stack =
  Icmp4.runIcmp4Layer (icmp4Handle stack) (ip4Handle stack)


-- IP4 Layer Interface ---------------------------------------------------------

class HasIP4 stack where
  ip4Handle :: stack -> IP4.IP4Handle

instance HasIP4 IP4.IP4Handle where ip4Handle = id

-- | Start the IP4 layer in a network stack.
startIP4Layer :: (HasArp stack, HasEthernet stack, HasIP4 stack)
              => stack -> IO ()
startIP4Layer stack =
  IP4.runIP4Layer (ip4Handle stack) (arpHandle stack) (ethernetHandle stack)

type Mtu = Int

-- | Add an IP4 address to a network stack.
addIP4Addr :: (HasArp stack, HasIP4 stack)
           => stack -> IP4Mask -> Mac -> Mtu -> IO ()
addIP4Addr stack mask mac mtu = do
  let (addr,_) = getMaskComponents mask
  Arp.addLocalAddress (arpHandle stack) addr mac
  IP4.addIP4RoutingRule (ip4Handle stack) (IP4.Direct mask addr mtu)

-- | Add a route for a network, via an address.
routeVia :: HasIP4 stack => stack -> IP4Mask -> IP4 -> IO ()
routeVia stack mask addr =
  IP4.addIP4RoutingRule (ip4Handle stack) (IP4.Indirect mask addr)

-- | Register a handler for an IP4 protocol
listenIP4Protocol :: HasIP4 stack
                  => stack -> IP4Protocol -> IP4.Handler -> IO ()
listenIP4Protocol stack = IP4.addIP4Handler (ip4Handle stack)

-- | Register a handler for an IP4 protocol
ignoreIP4Protocol :: HasIP4 stack => stack -> IP4Protocol -> IO ()
ignoreIP4Protocol stack = IP4.removeIP4Handler (ip4Handle stack)


-- Udp Layer Interface ---------------------------------------------------------

class HasUdp stack where
  udpHandle :: stack -> Udp.UdpHandle

instance HasUdp Udp.UdpHandle where udpHandle = id

-- | Start the UDP layer of a network stack.
startUdpLayer :: (HasIP4 stack, HasIcmp4 stack, HasUdp stack) => stack -> IO ()
startUdpLayer stack =
  Udp.runUdpLayer (udpHandle stack) (ip4Handle stack) (icmp4Handle stack)

-- | Add a handler for a UDP port.
addUdpHandler :: HasUdp stack => stack -> UdpPort -> Udp.Handler -> IO ()
addUdpHandler stack = Udp.addUdpHandler (udpHandle stack)

-- | Remove a handler for a UDP port.
removeUdpHandler :: HasUdp stack => stack -> UdpPort -> IO ()
removeUdpHandler stack = Udp.removeUdpHandler (udpHandle stack)

-- | Inject a packet into the UDP layer.
queueUdp :: HasUdp stack => stack -> IP4Header -> S.ByteString -> IO ()
queueUdp stack = Udp.queueUdp (udpHandle stack)

-- | Send a UDP packet.
sendUdp :: HasUdp stack
        => stack -> IP4 -> Maybe UdpPort -> UdpPort -> L.ByteString -> IO ()
sendUdp stack = Udp.sendUdp (udpHandle stack)


-- Tcp Layer Interface ---------------------------------------------------------

class HasTcp stack where
  tcpHandle :: stack -> Tcp.TcpHandle

instance HasTcp Tcp.TcpHandle where tcpHandle = id

-- | Start the TCP layer of a network stack.
startTcpLayer :: (HasIP4 stack, HasTimer stack, HasTcp stack) => stack -> IO ()
startTcpLayer stack =
  Tcp.runTcpLayer (tcpHandle stack) (ip4Handle stack) (timerHandle stack)

-- | Listen for incoming connections.
listen :: HasTcp stack => stack -> IP4 -> TcpPort -> IO Tcp.Socket
listen stack = Tcp.listen (tcpHandle stack)

-- | Make a remote connection.
connect :: HasTcp stack => stack -> IP4 -> TcpPort -> Maybe TcpPort -> IO Tcp.Socket
connect stack = Tcp.connect (tcpHandle stack)


-- Timer Layer Interface -------------------------------------------------------

class HasTimer stack where
  timerHandle :: stack -> Timer.TimerHandle

instance HasTimer Timer.TimerHandle where timerHandle = id

-- | Start the Timer layer in a network stack.
startTimerLayer :: HasTimer stack => stack -> IO ()
startTimerLayer stack = Timer.runTimerLayer (timerHandle stack)
