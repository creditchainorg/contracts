# creditchain-agents-mcp

An MCP server that lets an AI agent pay within an ERC-AGM mandate — and nothing more.

The key in this server's environment is a *mandate* key: the chain lets it spend only what its owner
granted, at the owner's rate, to the owner's recipients, until the owner revokes it. With a relayer
configured it holds no coins at all; it only signs.

| Tool | Does |
|---|---|
| `contracts` | addresses (same on every EVM chain) and the connected chain |
| `mandate_status` | limits, spent, spendable now, the owner's worst case in one sentence |
| `mandate_pay` | pay within the mandate, with a receipt of what was bought; refused before signing if outside the limits |
| `mandate_sign` | the same, returned as a signed authorization for an external relayer |
| `receipt_hash` | RFC 8785 + keccak256 commitment of a receipt document |
| `escape_status` | an account's post-quantum escape key, and whether the chain verifies ML-DSA natively |

```json
{ "mcpServers": { "creditchain": {
    "command": "npx", "args": ["creditchain-agents-mcp"],
    "env": { "CREDITCHAIN_RPC": "https://testnet.creditchain.org",
             "AGENT_PRIVATE_KEY": "<the mandate's agent key>",
             "RELAYER_PRIVATE_KEY": "<optional: pays gas>", "RELAY_FEE": "0" } } } }
```

`PAY_LIMIT` adds a local cap per payment. CreditChain mainnet is refused until the contracts are
audited, unless `CREDITCHAIN_ALLOW_MAINNET=1`. Tests: `npm test` against a local chain.
