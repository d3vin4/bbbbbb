# Third-party notices

bbbbbb builds on research and open-source work from the iOS sideloading community.
The components below are used or adapted; upstream license notices are preserved
alongside the reused material.

## Code adapted or integrated

- **StosVPN / LocalDevVPN** — https://github.com/SideStore/StosVPN,
  https://github.com/seomin0610/LocalDevVPN — MIT License, © 2025 SideStore Team.
  The embedded loopback tunnel (`Tunnel/`, `Shared/TunnelConstants.swift`) follows
  their packet-tunnel approach: a 10.7.0.x interface whose packet loop swaps
  source/destination so sandboxed apps can reach on-device services.
- **AirCard-iOS** — https://github.com/Mak5er/AirCard-iOS — MIT License,
  © 2026 Johnny Franks. The on-device pairing flow (Bonjour
  `_remotepairing-pairable-host._tcp` + PIN) and the AirliftFFI/AirTraffic
  surface are adopted for the AirLift access method.
- **idevice** — https://github.com/jkcoxson/idevice — MIT License,
  © 2026 Jackson Coxson. Device transport, Remote Pairing, RSD and FileService
  used by the AirLift access method.
- **KAMUI (kamui-escape)** — https://github.com/murk-sus/kamui-escape —
  MIT License. The multi-strategy container-query escape engine follows its
  class-13 / class-7 / class-12 / class-2 technique set.

## Techniques studied (no code copied)

- **forcequitOS/worse_query + bad_query** — GPLv3. Container-access research.
- **YangJiiii/3105** — GPLv3. MHA-C2 container discovery workflow, AirLift
  feature mapping, and Cleaner UX are studied and re-implemented.
- **jailbreakdotparty/Erosion** — customization toolbox UX reference.
- **0xjohnnydev/airlift + related PoCs** — AirTraffic/ATAirlock escape research.

Intended use: devices you own or are authorized to manage.
