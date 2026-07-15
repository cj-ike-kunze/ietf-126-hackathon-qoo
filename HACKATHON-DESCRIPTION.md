### Quality of Outcome (QoO): Evaluation, Tooling, and Ecosystem Development

* **Champion**
  Ike Kunze (ike.kunze@cujo.com)

* **Project Info**
  Quality of Outcome (QoO) is an IPPM framework for assessing network quality in the context of application requirements. The QoO draft is currently in the RFC Editor Queue. This project aims to help grow the QoO ecosystem through practical experimentation, tooling, implementation experience, and discussion around application profiles and measurements. A pre-built Docker-based testbed provides network emulation, active and passive measurements, live QoO score calculation, and Grafana dashboards. Participants can bring applications to test or use provided examples. The focus is not on validating QoO itself, but on exploring questions such as:
  - Which application profiles are useful?
  - When are category-based profiles sufficient?
  - How do different impairment types affect QoO scores?
  - How do different measurement approaches influence scoring?

* **Hackathon Activities**

  * **QoO under Network Impairments**: latency, jitter, and (burst) packet loss

  * **Comparing Network Quality Metrics**: QoO, responsiveness, and underlying network measurements
  
  * **Comparing Measurement Approaches**: active measurements (e.g., ping, TWAMP) and passive measurements (e.g., based on TCP or QUIC semantics)
  
  * **Exploring QoO Profiles**: application-specific versus category-based profiles

* **Expected Outcomes**
  - Evaluate multiple applications under controlled network impairments
  - Compare QoO with other network quality metrics
  - Identify scenarios where impairment type or profile selection materially affects scoring
  - Identify opportunities for future QoO profiles, tooling, measurements, and implementations
  - Generate implementation and operational experience that may help inform future community guidance, profile catalogs, or ecosystem development as QoO adoption matures

* **Related Documents**
  - QoO draft: https://datatracker.ietf.org/doc/draft-ietf-ippm-qoo/
  - Hackathon Network Emulation Framework: https://github.com/cj-ike-kunze/ietf-126-hackathon-qoo (will be made available before the hackathon)
