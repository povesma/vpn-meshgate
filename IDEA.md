# Idea

One stop shop self-hosted VPN.

## Challenge

Hundred percent of time my Mac should be connected to VPN. Primary VPN that I want to use is Mullvad VPN. This VPN has plenty of exit nodes, secure, and convenient to use.
However, from time to time, I need to connect to my private VPN or company VPN to access the respective resources. Ideally, I'd like to be connected to all three VPN's
at the same time, So I don't need to turn on or off respective VPN. However, I didn't manage to make all three VPNs work at the same time and I need to switch them one by one.
This is not convenient and not secure as both during switching and using a private our company VPN I lose privacy.

## Suggested solution

I run my own Headscale server and I have a Linux VPS, so I can be constantly connected to my private Tailscale network. Once I select pre-configured
exit node - it works according to configured "route rules" and selects the appropriate connection, and sends traffic via it.

## VPN Router

Create a docker compose that will serve as a tailscale Exit Node, and connect not always to the open Internet, but to:

1. Company VPN for IP addresses of ther Company (10.11.0.0/16).
1. Tailscale VPN for IPs 100.64.0.0/8
1. Mullvad VPN (all others)

