# I put Codex on my phone and found the dumbest SSH bug imaginable

*how I turned my NixOS dev box into an always-available Codex host, then ran into a compatibility value that AES-GCM does not even use.*

Codex on my phone is one of those setups that actually feels like the future. I can point it at my dev box, keep the repos and tools on the machine where they belong, and continue working without pretending my phone is a development environment.

the setup is good. getting SSH to connect was not.

did you know that Codex in the ChatGPT iOS app can silently hang for two minutes before authentication because SwiftNIOSSH requires your SSH server to advertise `hmac-sha2-256`, even though the negotiated AES-GCM cipher does not use it?

because that is exactly what happened to me.

I generated and verified multiple valid private keys. I tried PKCS#8, SEC1, RSA, password auth, and keyboard-interactive auth. I confirmed that Tailscale worked, confirmed that `sshd` received the connections, changed SSH algorithms, rebuilt NixOS repeatedly, and still got nowhere.

the connection only started working after I packet-captured the SSH handshake, decoded both KEXINIT messages, and added one compatibility MAC that the cipher does not use.

beautiful.

here is the complete journey, including the wrong turns, so hopefully nobody else has to spend this long proving that a valid private key is valid.

## what I was trying to do

the setup was simple. I wanted to connect Codex on my iPhone to my NixOS dev box over Tailscale.

the machine was already reachable inside the tailnet, OpenSSH was running, and I was not exposing SSH or the Codex App Server to the public internet. the relevant NixOS configuration already allowed password and public-key authentication:

```nix
services.openssh = {
  enable = true;
  openFirewall = false;
  settings = {
    AllowUsers = [ username ];
    KbdInteractiveAuthentication = false;
    PasswordAuthentication = true;
    PermitRootLogin = "no";
    PubkeyAuthentication = true;
  };
};
```

so, at a glance, this should have worked.

the failure happened before password or public-key authentication. none of the credentials were being checked.

## the private-key rabbit hole

the app first told me to enter a valid PKCS#8 or SEC1 PEM private key. fair enough. I generated an ECDSA P-256 key for the phone and tried both encodings.

the PKCS#8 version had the expected envelope:

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

I verified the key instead of trusting the file extension or my clipboard:

```sh
openssl pkey -in ~/.ssh/codex_phone.pkcs8.pem -check -noout
ssh-keygen -y -f ~/.ssh/codex_phone.pkcs8.pem | ssh-keygen -lf -
```

OpenSSL said `Key is valid`. `ssh-keygen` derived the expected public key and fingerprint. the public and private halves matched.

the app still rejected it.

I converted the key between SEC1 and PKCS#8. same error. I tried RSA. that was not accepted either. I temporarily installed the ECDSA public key on the dev box and restricted it to the phone's Tailscale address with an authorized-key `from=` rule. still nothing.

the importer behavior looks like a separate client bug, but it was not why the password connection hung. after getting password auth working, I removed the temporary phone key and its server-side configuration.

no private key material is included in this article.

## okay, was the network broken?

no.

the phone could reach the dev box over Tailscale. every attempt established a TCP connection to port 22, which ruled out the firewall, routing, DNS, and Tailscale reachability.

these were the useful checks:

```sh
ss -tinp '( sport = :22 or dport = :22 )'
journalctl -u sshd --since '10 minutes ago' --no-pager -o short-iso
```

`ss` showed live connections from the phone. two minutes later, `sshd` logged:

```text
Timeout before authentication for connection from CLIENT_IP to SERVER_IP
```

after enough retries, OpenSSH also applied a short source penalty for exceeding `LoginGraceTime`. that was normal protection against a client that opens connections and then does nothing. it was not the cause.

the useful part of the log was **before authentication**.

if the password were wrong, or if the public key were rejected, the server would log an authentication attempt. it logged none. I could rotate keys all day and it would not matter because the client never made it that far.

## surely enabling another auth method would fix it

nope.

I temporarily enabled keyboard-interactive authentication only for the phone's Tailscale address:

```text
Match Address CLIENT_IP
  KbdInteractiveAuthentication yes
Match all
```

the connection behaved the same because the client was still stuck before authentication. I removed the override once that was clear.

## maybe it was modern key exchange?

this was the next reasonable guess.

this machine was running OpenSSH 10.3 with NixOS's curated algorithm defaults. mobile SSH libraries do not always support the same algorithm set, so I temporarily added older, broadly supported KEX choices:

```text
ecdh-sha2-nistp256
diffie-hellman-group14-sha256
```

I rebuilt NixOS and confirmed that the new configuration was active. the server's KEXINIT packet got larger, so the change was on the wire.

the result was the same.

the phone sent 401 bytes. the server sent 814 bytes. then both sides stopped until `LoginGraceTime` expired.

so I removed the custom KEX list too. it had nothing to do with the failure.

## fine, packet-capture it

at this point the server logs had told me everything they could. the TCP connection worked, but the client never reached authentication.

I captured the Tailscale traffic directly:

```sh
tailscale debug capture --o -
```

my dev box did not have `tcpdump`, `tshark`, or Python installed. the first streaming parser failed because `python3` was missing, so I used a small Perl parser and decoded the pcap from standard input. I did not need to save a capture file containing the session traffic.

every connection looked like this:

```text
phone  -> server: SSH-2.0-SwiftNIOSSH_1.0
server -> phone:  SSH-2.0-OpenSSH_10.3
phone  -> server: SSH_MSG_KEXINIT
server -> phone:  SSH_MSG_KEXINIT
phone  -> server: nothing else
```

the client received the server's KEXINIT message and never sent `SSH_MSG_KEX_ECDH_INIT`. it was not stuck on a password prompt or key signature. it was stuck choosing transport algorithms.

## what both sides advertised

the captured SwiftNIOSSH proposal advertised:

- **key exchange:** ECDH P-384, P-256, P-521, and Curve25519
- **host keys:** Ed25519 and ECDSA P-384, P-256, and P-521
- **ciphers:** AES-256-GCM and AES-128-GCM
- **MACs:** `hmac-sha2-256` only
- **compression:** `none`

the server had compatible key-exchange algorithms, an Ed25519 host key, compatible AES-GCM ciphers, and `none` compression.

the only lists without an intersection were the MAC lists:

```text
phone:
  hmac-sha2-256

server:
  hmac-sha2-512-etm@openssh.com
  hmac-sha2-256-etm@openssh.com
  umac-128-etm@openssh.com
```

this is where the mismatch stopped making sense. AES-GCM is an AEAD cipher. it provides authenticated encryption itself and does not use a separate SSH MAC.

to make sure OpenSSH was not the problem, I constrained a local OpenSSH client to the same KEX, host key, AES-GCM ciphers, and `hmac-sha2-256`. it negotiated successfully and reached authentication.

the server's algorithm set was valid. SwiftNIOSSH was the difference.

## the actual bug

SwiftNIOSSH advertises a placeholder MAC when all of its configured ciphers are AEAD ciphers. that is fine because the SSH KEXINIT structure still contains MAC name-lists.

the bug is that SwiftNIOSSH requires the client and server MAC lists to intersect, even though the selected AES-GCM cipher will never use the result.

ETM-only server policies, including NixOS's curated defaults, advertise names such as `hmac-sha2-256-etm@openssh.com`. those do not match SwiftNIOSSH's plain `hmac-sha2-256` placeholder, so key exchange fails.

this was not custom SSH hardening I added. NixOS enables `services.openssh.enableRecommendedAlgorithms` by default, which replaces upstream OpenSSH's MAC list with a curated ETM-only list. upstream OpenSSH's defaults include plain `hmac-sha2-256`, so a stock OpenSSH configuration would normally hide this bug. NixOS's defaults exposed it.

Codex in the iOS app did not show a key-exchange negotiation error. it waited until the server's two-minute pre-authentication timeout expired.

the issue is already documented upstream:

- [Allow AEAD ciphers to ignore compatibility MAC negotiation](https://github.com/apple/swift-nio-ssh/pull/236)
- [Advertise ETM MAC names for AEAD-only clients](https://github.com/apple/swift-nio-ssh/pull/243)

the first pull request mentions Codex SSH hanging against NixOS on OpenSSH 10.3p1. at the time I diagnosed this, the fix was not in the client I was running.

so the private key was valid. the password was fine. Tailscale worked. OpenSSH worked. the client was hanging on a compatibility value that the negotiated cipher would not use.

## the one dumb thing that fixed everything

this was the working NixOS change:

```nix
services.openssh.settings = {
  # Work around SwiftNIOSSH requiring MAC overlap for AEAD ciphers.
  # https://github.com/apple/swift-nio-ssh/pull/236
  Macs = [
    "hmac-sha2-512-etm@openssh.com"
    "hmac-sha2-256-etm@openssh.com"
    "umac-128-etm@openssh.com"
    "hmac-sha2-256"
  ];
};
```

the first three entries preserve the NixOS-curated defaults already in effect. the last entry gives SwiftNIOSSH the list overlap it requires.

when Codex negotiates AES-GCM, `hmac-sha2-256` is not used to protect the connection. AES-GCM provides authenticated encryption. for this Codex connection, the extra name only gets the client past the negotiation check.

the setting is global because SSH transport algorithms are selected before the server has an authenticated user. `hmac-sha2-256` is still a sound MAC, although the non-ETM construction is less preferable than the existing ETM defaults. my SSH service also remains accessible only through the private network, not the public internet.

I validated the configuration:

```sh
cd ~/dotfiles
nix flake check --no-build --no-update-lock-file "path:$PWD"
```

then rebuilt the dev box:

```sh
sudo nixos-rebuild switch --flake ~/dotfiles#your-host
```

no reboot. no new key. no password change.

the same connection worked immediately.

## what would fix this

the negotiation bug is in SwiftNIOSSH, but Codex ships the client, so there are a few things that would fix this:

1. update or patch the bundled SwiftNIOSSH dependency with the upstream AEAD negotiation fix;
2. add a regression test against an OpenSSH server that advertises only ETM MAC names;
3. surface `keyExchangeNegotiationFailure` instead of waiting for the server timeout; and
4. separately investigate why the private-key importer rejected verified SEC1 and PKCS#8 keys.

this is not a custom SSH daemon. it is OpenSSH on NixOS, reached through Tailscale. this behavior makes a transport-negotiation bug look like a credential or network failure and does not give the user enough information to debug it.

## notes for future me

if this ever regresses, I am not generating five more private keys first.

1. confirm that the client reaches port 22 with `ss -tin`;
2. check `journalctl -u sshd` and distinguish **before authentication** from a credential rejection;
3. watch the socket byte counters, because a stable small byte count means transport negotiation stalled;
4. capture one handshake with `tailscale debug capture --o -`;
5. verify whether the client sends the first key-exchange packet after KEXINIT; and
6. compare KEX, host key, cipher, MAC, and compression lists before changing authentication again.

the main lesson is that an SSH screen eventually saying “connection failed” does not mean your credential failed.

in this case, authentication was never attempted. 😊

## references

- [OpenAI remote connections documentation](https://learn.chatgpt.com/docs/remote-connections)
- [SwiftNIOSSH](https://github.com/apple/swift-nio-ssh)
- [SwiftNIOSSH AEAD/MAC negotiation fix](https://github.com/apple/swift-nio-ssh/pull/236)
- [alternative SwiftNIOSSH compatibility proposal](https://github.com/apple/swift-nio-ssh/pull/243)
