package main

import (
	"strconv"
	"sync"
	"time"
)

const (
	maxLatencySamples = 256
	maxPendingAcks    = 64
	pendingAckTTL     = 5 * time.Second
)

// FlowKey identifies a flow independent of packet direction.
type FlowKey struct {
	AddrA string
	PortA uint16
	AddrB string
	PortB uint16
}

func flowKey(srcIP string, srcPort uint16, dstIP string, dstPort uint16) FlowKey {
	if srcIP < dstIP || (srcIP == dstIP && srcPort < dstPort) {
		return FlowKey{AddrA: srcIP, PortA: srcPort, AddrB: dstIP, PortB: dstPort}
	}
	return FlowKey{AddrA: dstIP, PortA: dstPort, AddrB: srcIP, PortB: srcPort}
}

// FlowMetrics holds the running metrics for one flow. The first packet seen
// for a flow fixes ClientAddr/ClientPort; direction for subsequent packets
// is derived by comparing source address/port against that. RTT is sampled
// continuously (data segment -> covering ACK), not just at handshake, so
// enough samples build up for percentile-based QoO scoring.
type FlowMetrics struct {
	mu sync.Mutex

	ClientAddr string
	ClientPort uint16
	ServerAddr string
	ServerPort uint16
	Category   string
	Protocol   string // "tcp", "udp", or "icmp" - set once at flow creation

	packets     uint64
	windowStart time.Time
	windowBytes uint64

	ThroughputMbps float64

	maxSeqClientToServer uint32
	seenClientToServer   bool
	maxSeqServerToClient uint32
	seenServerToClient   bool
	Retransmits          uint64

	pendingClientAcks map[uint32]time.Time // client->server data awaiting server's ACK
	pendingServerAcks map[uint32]time.Time // server->client data awaiting client's ACK

	pendingICMPEcho map[uint16]time.Time // echo request seq awaiting its reply

	latencySamples []float64
	RTTMs          float64
	JitterMs       float64

	LastSeen time.Time
}

// onPacket updates flow state. hasTCP false means non-TCP traffic (only
// byte/throughput accounting applies).
func (f *FlowMetrics) onPacket(isClientToServer bool, byteLen int, tcpSeq, tcpAck, tcpPayloadLen uint32, isSYN, isACK, hasTCP bool, now time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.packets++
	f.LastSeen = now

	if f.windowStart.IsZero() {
		f.windowStart = now
	}
	f.windowBytes += uint64(byteLen)
	if elapsed := now.Sub(f.windowStart).Seconds(); elapsed >= 1 {
		f.ThroughputMbps = float64(f.windowBytes) * 8 / 1e6 / elapsed
		f.windowBytes = 0
		f.windowStart = now
	}

	if !hasTCP {
		return
	}

	if tcpPayloadLen > 0 {
		if isClientToServer {
			if f.seenClientToServer && tcpSeq+tcpPayloadLen <= f.maxSeqClientToServer {
				f.Retransmits++
			} else {
				f.maxSeqClientToServer = tcpSeq + tcpPayloadLen
				f.seenClientToServer = true
			}
		} else {
			if f.seenServerToClient && tcpSeq+tcpPayloadLen <= f.maxSeqServerToClient {
				f.Retransmits++
			} else {
				f.maxSeqServerToClient = tcpSeq + tcpPayloadLen
				f.seenServerToClient = true
			}
		}
	}

	if isSYN && !isACK && isClientToServer {
		if f.pendingServerAcks == nil {
			f.pendingServerAcks = make(map[uint32]time.Time)
		}
		// SYN consumes one sequence number; the SYN-ACK's ack covers seq+1.
		f.pendingServerAcks[tcpSeq+1] = now
	}

	if isClientToServer {
		if tcpPayloadLen > 0 {
			f.trackPending(true, tcpSeq+tcpPayloadLen, now)
		}
		if isACK {
			f.matchPending(false, tcpAck, now)
		}
	} else {
		if tcpPayloadLen > 0 {
			f.trackPending(false, tcpSeq+tcpPayloadLen, now)
		}
		if isACK {
			f.matchPending(true, tcpAck, now)
		}
	}
}

// trackPending records that a data segment sent in the given direction
// expects to be acknowledged at expectedAck.
func (f *FlowMetrics) trackPending(clientToServer bool, expectedAck uint32, now time.Time) {
	pending := f.pendingFor(clientToServer, true)
	pending[expectedAck] = now
	if len(pending) > maxPendingAcks {
		for seq, t := range pending {
			if now.Sub(t) > pendingAckTTL {
				delete(pending, seq)
			}
		}
	}
}

// matchPending resolves any outstanding sends in the given direction covered
// by ack, recording an RTT sample for each.
func (f *FlowMetrics) matchPending(clientToServer bool, ack uint32, now time.Time) {
	pending := f.pendingFor(clientToServer, false)
	for seq, sentAt := range pending {
		if seq <= ack {
			f.recordLatencySample(now.Sub(sentAt).Seconds() * 1000)
			delete(pending, seq)
		}
	}
}

// onICMPEcho tracks passive ping (ICMP echo) traffic - same byte/throughput
// accounting as onPacket, plus RTT sampled from request->reply matching by
// sequence number (id is already folded into the flow key by processPacket,
// so two concurrent pings to the same host don't cross-match each other's
// sequences).
func (f *FlowMetrics) onICMPEcho(isRequest bool, seq uint16, byteLen int, now time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.packets++
	f.LastSeen = now

	if f.windowStart.IsZero() {
		f.windowStart = now
	}
	f.windowBytes += uint64(byteLen)
	if elapsed := now.Sub(f.windowStart).Seconds(); elapsed >= 1 {
		f.ThroughputMbps = float64(f.windowBytes) * 8 / 1e6 / elapsed
		f.windowBytes = 0
		f.windowStart = now
	}

	if f.pendingICMPEcho == nil {
		f.pendingICMPEcho = make(map[uint16]time.Time)
	}

	if isRequest {
		f.pendingICMPEcho[seq] = now
		if len(f.pendingICMPEcho) > maxPendingAcks {
			for s, t := range f.pendingICMPEcho {
				if now.Sub(t) > pendingAckTTL {
					// aged out with no reply seen - counts as loss, same
					// way a TCP retransmit does for Snapshot()'s loss ratio.
					f.Retransmits++
					delete(f.pendingICMPEcho, s)
				}
			}
		}
		return
	}

	if sentAt, ok := f.pendingICMPEcho[seq]; ok {
		f.recordLatencySample(now.Sub(sentAt).Seconds() * 1000)
		delete(f.pendingICMPEcho, seq)
	}
}

func (f *FlowMetrics) pendingFor(clientToServer bool, createIfNil bool) map[uint32]time.Time {
	if clientToServer {
		if f.pendingClientAcks == nil && createIfNil {
			f.pendingClientAcks = make(map[uint32]time.Time)
		}
		return f.pendingClientAcks
	}
	if f.pendingServerAcks == nil && createIfNil {
		f.pendingServerAcks = make(map[uint32]time.Time)
	}
	return f.pendingServerAcks
}

func (f *FlowMetrics) recordLatencySample(ms float64) {
	f.latencySamples = append(f.latencySamples, ms)
	if len(f.latencySamples) > maxLatencySamples {
		f.latencySamples = f.latencySamples[len(f.latencySamples)-maxLatencySamples:]
	}

	if f.RTTMs == 0 {
		f.RTTMs = ms
		return
	}
	d := ms - f.RTTMs
	if d < 0 {
		d = -d
	}
	f.JitterMs += (d - f.JitterMs) / 16
	f.RTTMs = ms
}

// FlowSnapshot is a consistent, lock-free-to-read copy of a flow's current
// metrics, taken under a single lock acquisition.
type FlowSnapshot struct {
	Label          string
	Category       string
	Protocol       string
	ClientPort     uint16
	ServerPort     uint16
	RTTMs          float64
	JitterMs       float64
	ThroughputMbps float64
	LossRatio      float64
	Packets        uint64
	LatencySamples []float64
}

func (f *FlowMetrics) Snapshot() FlowSnapshot {
	f.mu.Lock()
	defer f.mu.Unlock()

	loss := 0.0
	if f.packets > 0 {
		loss = float64(f.Retransmits) / float64(f.packets)
	}

	samples := make([]float64, len(f.latencySamples))
	copy(samples, f.latencySamples)

	return FlowSnapshot{
		Label:          f.ClientAddr + ":" + strconv.Itoa(int(f.ClientPort)) + "->" + f.ServerAddr + ":" + strconv.Itoa(int(f.ServerPort)),
		Category:       f.Category,
		Protocol:       f.Protocol,
		ClientPort:     f.ClientPort,
		ServerPort:     f.ServerPort,
		RTTMs:          f.RTTMs,
		JitterMs:       f.JitterMs,
		ThroughputMbps: f.ThroughputMbps,
		LossRatio:      loss,
		Packets:        f.packets,
		LatencySamples: samples,
	}
}

func (f *FlowMetrics) lastSeen() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.LastSeen
}

// MetricStore is the concurrency-safe collection of all known flows plus
// the gateway's currently active impairment profile.
type MetricStore struct {
	mu            sync.Mutex
	flows         map[FlowKey]*FlowMetrics
	activeProfile string
	qooProfile    string
	qooConfig     QoOConfig
	category      string
}

func NewMetricStore(category string) *MetricStore {
	return &MetricStore{
		flows:      make(map[FlowKey]*FlowMetrics),
		qooProfile: "manual",
		qooConfig:  defaultQoOConfig(),
		category:   category,
	}
}

// GetOrCreate returns the flow for key, creating it (with src as the client
// side) on first sight. Returns whether srcAddr/srcPort is the client side.
func (s *MetricStore) GetOrCreate(key FlowKey, srcAddr string, srcPort uint16, dstAddr string, dstPort uint16, protocol string) (*FlowMetrics, bool) {
	s.mu.Lock()
	fm, ok := s.flows[key]
	if !ok {
		fm = &FlowMetrics{
			ClientAddr: srcAddr,
			ClientPort: srcPort,
			ServerAddr: dstAddr,
			ServerPort: dstPort,
			Category:   s.category,
			Protocol:   protocol,
		}
		s.flows[key] = fm
	}
	s.mu.Unlock()

	isClientToServer := srcAddr == fm.ClientAddr && srcPort == fm.ClientPort
	return fm, isClientToServer
}

func (s *MetricStore) SetActiveProfile(p string) {
	s.mu.Lock()
	s.activeProfile = p
	s.mu.Unlock()
}

func (s *MetricStore) ActiveProfile() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.activeProfile
}

func (s *MetricStore) SetQoOProfile(p string) {
	s.mu.Lock()
	s.qooProfile = p
	s.mu.Unlock()
}

func (s *MetricStore) QoOProfile() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.qooProfile
}

func (s *MetricStore) SetQoOConfig(cfg QoOConfig) {
	s.mu.Lock()
	s.qooConfig = cfg
	s.mu.Unlock()
}

func (s *MetricStore) QoOConfig() QoOConfig {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.qooConfig
}

// Snapshot returns all live flows, dropping (and forgetting) any that have
// been idle for more than 30s.
func (s *MetricStore) Snapshot() []*FlowMetrics {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-30 * time.Second)
	out := make([]*FlowMetrics, 0, len(s.flows))
	for k, fm := range s.flows {
		if fm.lastSeen().Before(cutoff) {
			delete(s.flows, k)
			continue
		}
		out = append(out, fm)
	}
	return out
}
