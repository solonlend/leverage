// Shared by UniV3DualVault and UniV4DualVault; all tuple fields are uint256.
export const vaultAbi = [
  ...['nextPositionId', 'ownerOf', 'isHealthy'].map(name => ({
    type: 'function', name, stateMutability: 'view',
    inputs: name === 'nextPositionId' ? [] : [{ name: 'id', type: 'uint256' }],
    outputs: [{ type: name === 'ownerOf' ? 'address' : name === 'isHealthy' ? 'bool' : 'uint256' }],
  })),
  {
    type: 'function', name: 'liquidate', stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }, {
      name: 'lp', type: 'tuple', components: ['ratioBps', 'minSeizeValue', 'deadline'].map(name => ({ name, type: 'uint256' })),
    }], outputs: [{ name: 'fullyClosed', type: 'bool' }],
  },
];
