package main

import (
	"io"
	"log"
	"os"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"github.com/google/gopacket/pcapgo"
)

// reopenInterval bounds how long a single tailOnce call polls its open file
// descriptor before returning (nil, not an error) to force TailPcap to open
// a fresh one. Gateway appends to this bind-mounted file from another
// container, and periodically reopening keeps packet visibility reliable
// across host/container filesystem buffering behavior.
const reopenInterval = 3 * time.Second

// TailPcap follows path forever, reopening periodically (see
// reopenInterval) and also reprocessing from the start on any real error
// (e.g. tcpdump not started yet, or a truncated read mid-write) since the
// file grows without ever being replaced during a demo run.
func TailPcap(path string, store *MetricStore) {
	for {
		if err := tailOnce(path, store); err != nil {
			log.Printf("pcap tail error: %v; retrying in 2s", err)
			time.Sleep(2 * time.Second)
		}
	}
}

func tailOnce(path string, store *MetricStore) error {
	for {
		if _, err := os.Stat(path); err == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}

	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	reader, err := pcapgo.NewReader(f)
	if err != nil {
		return err
	}

	// The capture's actual link-layer framing depends on which interface
	// gateway's tcpdump ran on: a normal Docker bridge veth is Ethernet, but
	// the macOS WireGuard fallback (LAN_IFACE=wg0 - see gateway/entrypoint.sh)
	// is a raw IP tunnel with NO Ethernet header at all. Decoding always as
	// LayerTypeEthernet misparses every
	// single packet on a wg0 capture (it reads real IP-header bytes as a
	// fake Ethernet header), which silently produced zero flows for TCP,
	// UDP, and ICMP alike on this setup.
	//
	// gopacket.NewPacket wants a Decoder, and layers.LinkType implements
	// that directly - pass the link type itself, not .LayerType(): this
	// method just reports the resulting layer's classification and is
	// left unset (zero value) for some link types including LinkTypeRaw,
	// so calling it here silently produced a no-op decoder for exactly
	// the wg0 case this fix targets.
	decodeAs := reader.LinkType()

	deadline := time.Now().Add(reopenInterval)
	for {
		if time.Now().After(deadline) {
			return nil
		}
		data, ci, err := reader.ReadPacketData()
		if err == io.EOF {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		if err != nil {
			return err
		}
		processPacket(data, ci.Timestamp, decodeAs, store)
	}
}

func processPacket(data []byte, ts time.Time, decodeAs layers.LinkType, store *MetricStore) {
	packet := gopacket.NewPacket(data, decodeAs, gopacket.NoCopy)

	ipLayer := packet.Layer(layers.LayerTypeIPv4)
	if ipLayer == nil {
		return
	}
	ip := ipLayer.(*layers.IPv4)

	// ICMP echo (ping) has no ports - the echo identifier plays that role
	// instead, so request/reply for one ping session key together the same
	// way a TCP/UDP 4-tuple does, and two concurrent pings don't collide.
	if icmpLayer := packet.Layer(layers.LayerTypeICMPv4); icmpLayer != nil {
		icmp := icmpLayer.(*layers.ICMPv4)
		typ := icmp.TypeCode.Type()
		if typ != layers.ICMPv4TypeEchoRequest && typ != layers.ICMPv4TypeEchoReply {
			return
		}
		srcAddr, dstAddr := ip.SrcIP.String(), ip.DstIP.String()
		key := flowKey(srcAddr, icmp.Id, dstAddr, icmp.Id)
		fm, _ := store.GetOrCreate(key, srcAddr, icmp.Id, dstAddr, icmp.Id, "icmp")
		fm.onICMPEcho(typ == layers.ICMPv4TypeEchoRequest, icmp.Seq, len(data), ts)
		return
	}

	var srcPort, dstPort uint16
	var tcp *layers.TCP
	protocol := ""
	if tcpLayer := packet.Layer(layers.LayerTypeTCP); tcpLayer != nil {
		tcp = tcpLayer.(*layers.TCP)
		srcPort, dstPort = uint16(tcp.SrcPort), uint16(tcp.DstPort)
		protocol = "tcp"
	} else if udpLayer := packet.Layer(layers.LayerTypeUDP); udpLayer != nil {
		udp := udpLayer.(*layers.UDP)
		srcPort, dstPort = uint16(udp.SrcPort), uint16(udp.DstPort)
		protocol = "udp"
	} else {
		return
	}

	srcAddr, dstAddr := ip.SrcIP.String(), ip.DstIP.String()
	key := flowKey(srcAddr, srcPort, dstAddr, dstPort)
	fm, isClientToServer := store.GetOrCreate(key, srcAddr, srcPort, dstAddr, dstPort, protocol)

	if tcp != nil {
		fm.onPacket(isClientToServer, len(data), tcp.Seq, tcp.Ack, uint32(len(tcp.Payload)), tcp.SYN, tcp.ACK, true, ts)
		return
	}
	fm.onPacket(isClientToServer, len(data), 0, 0, 0, false, false, false, ts)
}
