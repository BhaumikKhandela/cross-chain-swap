export const CONFIG = {
  PACKAGE_ID: "YOUR_PUBLISHED_PACKAGE_ID", // Replace with your actual package ID
  FACTORY_OBJECT_ID: "YOUR_FACTORY_OBJECT_ID", // Replace with factory object ID
  MERKLE_VALIDATOR_ID: "YOUR_MERKLE_VALIDATOR_ID", // Replace with validator ID
  CLOCK_OBJECT_ID: "0x6", // Sui system clock (this is constant)

  // Network configuration
  NETWORK: "testnet", // or 'mainnet' or 'devnet'

  // RPC endpoints
  RPC_URLS: {
    mainnet: "https://fullnode.mainnet.sui.io",
    testnet: "https://fullnode.testnet.sui.io",
    devnet: "https://fullnode.devnet.sui.io",
  },
};
