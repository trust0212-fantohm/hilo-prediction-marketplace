# Hilov5-contract

## Environment Setup

To run deployment and management scripts, you need to set up environment variables:

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit the `.env` file to include your private key (without the `0x` prefix) and RPC URLs:
   ```
   DEPLOYER_PRIVATE_KEY=your_private_key_here_without_0x_prefix
   RPC_URL=https://your-rpc-url
   ```

3. Make sure to keep your `.env` file secure and never commit it to version control.

## Deployment Scripts

The project includes several deployment scripts that use the private key from your `.env` file:

- `scripts/deployUAT.js` - Deploy to the UAT environment
- `scripts/changeUAT.js` - Make changes to the UAT environment
- `scripts/deployLog.js` - Record deployment information

To run any of these scripts:

```bash
npx hardhat run scripts/deployUAT.js --network targetNetwork
```# hilo-prediction-marketplace
