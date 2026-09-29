# The `netnewswire` overlay

One file that [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) at commit
`b4361413fc1850110f9f42652f0f84e7a51e9d64` generates before its build and does not commit,
laid over the clone by the end-to-end harness before `prepare` (B-76, B-77):

- `Modules/Secrets/Sources/Secrets/SecretKey.swift`

The project generates it from `SecretKey.swift.gyb` beside it in the build pre-action of
its `NetNewsWire` scheme, `buildscripts/updateSecrets.sh`, which runs gyb over every
`.gyb` in the tree. The template reads six secrets from the environment
(`MERCURY_CLIENT_ID`, `FEEDLY_CLIENT_SECRET`, …) and writes each XOR-ed with a salt of
64 bytes it draws from `os.urandom`. A scheme action is outside a hermetic build — Semel
runs no script whose output depends on the machine that runs it, and this one's does twice
over, through the environment and the random salt — so `semel-swift prepare` names the
file and the pre-action instead of running it (`Not generated: …`).

This file is what the script writes for a developer who has no secrets, which is what a
fresh clone builds as: gyb run once, with an empty environment, over the pinned
template (`env -i PATH=/usr/bin:/bin python3 buildscripts/gyb --line-directive '' -o
SecretKey.swift SecretKey.swift.gyb`). Every secret is empty, so the salt — the one run's
random bytes, kept as they came out — decodes nothing and matters to nothing but the
file's bytes, which the overlay now fixes.

`lay` accepts it though the checkout has no file at its path, because the template beside
that path is in the checkout: the template pins where the output goes, as a file the
checkout has pins a correction.

`LICENSE` is NetNewsWire's own, unchanged, laid over the checkout's identical copy: the
generated file is the project's template's output, under its MIT license. This `README.md`
is the overlay's and is not laid over the clone.
