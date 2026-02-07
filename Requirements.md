# Matrix Voice/Video Communication - Requirements

## Server Requirements

- A Matrix homeserver (Synapse is the main implementation, though Dendrite and Conduit are lighter alternatives)
- Runs on Linux (can be deployed via Docker for easier setup)
- TURN server for NAT traversal when direct P2P connections fail
- Domain name and TLS certificate for secure connections

## Client Requirements

- Element clients (available for web, Windows, macOS, Linux, iOS, and Android)
- All clients need to support voice/video calls and E2E encryption
- Users should enable E2E encryption for rooms/calls
- Device verification between participants to prevent MITM attacks

## Key Setup Steps

1. Deploy Matrix homeserver on your infrastructure
2. Configure TURN server for reliable connectivity
3. Install Element clients on all devices
4. Enable E2E encryption for conversations
5. Verify device keys between users (similar to Signal safety numbers)

## What This Gives You

- Self-hosted infrastructure (full control over your data)
- End-to-end encrypted voice/video calls
- Protection against MITM attacks (including from server operator)
- Peer-to-peer connections when possible, server relay when needed
- Text chat, file sharing, and screen sharing as bonuses

## Trade-offs

The main trade-off is complexity - Matrix/Element requires more setup than simpler solutions, but it is the only option that meets all the security requirements.
