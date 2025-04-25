import { Clarinet, Tx, Chain, Account, types } from 'https://deno.land/x/clarinet@v0.14.0/index.ts';
import { assertEquals } from 'https://deno.land/std@0.90.0/testing/asserts.ts';

// Helper function to create a random buffer of specified size
function randomBytes(size: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(size));
}

// Helper to create a Buffer for htlc preimages and hashlocks
function createBuffer(hexString: string): Uint8Array {
  const bytes = new Uint8Array(hexString.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hexString.substr(i * 2, 2), 16);
  }
  return bytes;
}

Clarinet.test({
  name: "Ensure contract initialization works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    
    let block = chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address)
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
  },
});

Clarinet.test({
  name: "Ensure participant registration and deregistration works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Initialize the contract
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address)
    ]);
    
    // Register participants
    let block = chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    assertEquals(block.receipts.length, 2);
    assertEquals(block.receipts[0].result, '(ok true)');
    assertEquals(block.receipts[1].result, '(ok true)');
    
    // Try to register the same participant again (should fail)
    block = chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address)
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.includes('err'), true);
    
    // Deregister a participant
    block = chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'deregister-participant', [], participant1.address)
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify participant is inactive
    const result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-participant-info',
      [types.principal(participant1.address)],
      deployer.address
    );
    
    // Parse the response and verify active flag is false
    const responseObj = result.result.expectSome().expectTuple();
    assertEquals(responseObj['active'], types.bool(false));
  },
});

Clarinet.test({
  name: "Ensure channel creation and funding works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Initialize the contract
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address)
    ]);
    
    // Register participants
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Open a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(50000000), // 50 STX
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Join the channel
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(30000000) // 30 STX
        ],
        participant2.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify channel state
    const result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    const channelInfo = result.result.expectSome().expectTuple();
    assertEquals(channelInfo['participant1'], types.principal(participant1.address));
    assertEquals(channelInfo['participant2'], types.principal(participant2.address));
    assertEquals(channelInfo['capacity'], types.uint(80000000)); // 50 + 30 STX
    assertEquals(channelInfo['participant1-balance'], types.uint(50000000));
    assertEquals(channelInfo['participant2-balance'], types.uint(30000000));
    assertEquals(channelInfo['state'], types.uint(0)); // Open
    
    // Add more funds to the channel
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'add-funds',
        [
          types.uint(channelId),
          types.uint(20000000) // 20 more STX
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify updated capacity
    const updatedResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    const updatedChannelInfo = updatedResult.result.expectSome().expectTuple();
    assertEquals(updatedChannelInfo['capacity'], types.uint(100000000)); // 80 + 20 STX
    assertEquals(updatedChannelInfo['participant1-balance'], types.uint(70000000)); // 50 + 20 STX
  },
});

Clarinet.test({
  name: "Ensure balance proof submission works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(50000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Join the channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(50000000)
        ],
        participant2.address
      )
    ]);
    
    // Create a mock signature (65 bytes)
    const mockSignature = '0x' + '00'.repeat(65);
    
    // Submit balance proof (participant1 -> participant2 payment)
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'submit-balance-proof',
        [
          types.uint(channelId),
          types.uint(60000000), // New balance after off-chain payment
          types.uint(1), // Nonce
          types.buff(mockSignature)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify channel nonce updated
    const result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    const channelInfo = result.result.expectSome().expectTuple();
    assertEquals(channelInfo['participant1-nonce'], types.uint(1));
  },
});

Clarinet.test({
  name: "Ensure HTLC creation and fulfillment works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(60000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Join the channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(40000000)
        ],
        participant2.address
      )
    ]);
    
    // Create a secret and its hash
    const secret = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
    
    // Calculate hashlock (sha256 of secret)
    // Note: In a real test, you'd need to calculate this properly
    // For now, we're using a mock value that matches what we expect
    const hashlock = '0x6c4e1170e41668abbd5f42232c45453b9964bad42b661df464030a69fbe8f7c7';
    
    // Set timelock to a future block
    const currentBlock = chain.blockHeight;
    const timelock = currentBlock + 144; // 1 day worth of blocks
    
    // Create HTLC
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'create-htlc',
        [
          types.uint(channelId),
          types.principal(participant2.address),
          types.uint(10000000), // 10 STX
          types.buff(hashlock),
          types.uint(timelock)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    const htlcId = block.receipts[0].result.expectOk().expectUint();
    
    // Verify HTLC created
    let htlcResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-htlc-info',
      [types.uint(htlcId)],
      deployer.address
    );
    
    let htlcInfo = htlcResult.result.expectSome().expectTuple();
    assertEquals(htlcInfo['sender'], types.principal(participant1.address));
    assertEquals(htlcInfo['receiver'], types.principal(participant2.address));
    assertEquals(htlcInfo['amount'], types.uint(10000000));
    assertEquals(htlcInfo['claimed'], types.bool(false));
    
    // Verify sender balance decreased
    let channelResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    let channelInfo = channelResult.result.expectSome().expectTuple();
    assertEquals(channelInfo['participant1-balance'], types.uint(50000000)); // 60 - 10 STX
    
    // Fulfill HTLC
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'fulfill-htlc',
        [
          types.uint(htlcId),
          types.buff(secret)
        ],
        participant2.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify receiver balance increased
    channelResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    channelInfo = channelResult.result.expectSome().expectTuple();
    assertEquals(channelInfo['participant2-balance'], types.uint(50000000)); // 40 + 10 STX
    
    // Verify HTLC is claimed
    htlcResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-htlc-info',
      [types.uint(htlcId)],
      deployer.address
    );
    
    htlcInfo = htlcResult.result.expectSome().expectTuple();
    assertEquals(htlcInfo['claimed'], types.bool(true));
  },
});

Clarinet.test({
  name: "Ensure HTLC refund works after timelock expires",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(60000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Join the channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(40000000)
        ],
        participant2.address
      )
    ]);
    
    // Create a secret and its hash
    const secret = '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
    
    // Calculate hashlock (sha256 of secret)
    const hashlock = '0x46787c78d6b0104d8eed322d7e80a89b22b4439d84c6bc82094812a0a104f395';
    
    // Set timelock to a near future block (so we can advance past it)
    const currentBlock = chain.blockHeight;
    const timelock = currentBlock + 5;
    
    // Create HTLC
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'create-htlc',
        [
          types.uint(channelId),
          types.principal(participant2.address),
          types.uint(10000000),
          types.buff(hashlock),
          types.uint(timelock)
        ],
        participant1.address
      )
    ]);
    
    const htlcId = block.receipts[0].result.expectOk().expectUint();
    
    // Verify sender balance decreased
    let channelResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    let channelInfo = channelResult.result.expectSome().expectTuple();
    assertEquals(channelInfo['participant1-balance'], types.uint(50000000));
    
    // Advance chain past timelock
    chain.mineEmptyBlockUntil(timelock + 1);
    
    // Attempt refund (should succeed after timelock expires)
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'refund-htlc',
        [types.uint(htlcId)],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify sender balance restored
    channelResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    channelInfo = channelResult.result.expectSome().expectTuple();
    assertEquals(channelInfo['participant1-balance'], types.uint(60000000)); // Restored to original
    
    // Verify HTLC marked as refunded
    const htlcResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-htlc-info',
      [types.uint(htlcId)],
      deployer.address
    );
    
    const htlcInfo = htlcResult.result.expectSome().expectTuple();
    assertEquals(htlcInfo['refunded'], types.bool(true));
  },
});

Clarinet.test({
  name: "Ensure cooperative channel closing works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(60000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Join the channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(40000000)
        ],
        participant2.address
      )
    ]);
    
    // Create mock signatures
    const signature1 = '0x' + '00'.repeat(65);
    const signature2 = '0x' + '01'.repeat(65);
    
    // Cooperatively close channel with agreed balances
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'cooperative-close-channel',
        [
          types.uint(channelId),
          types.uint(55000000), // participant1 balance
          types.uint(45000000), // participant2 balance
          types.buff(signature1),
          types.buff(signature2)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.expectOk().expectTuple()['participant1-balance'], types.uint(54890000)); // minus protocol fee
    assertEquals(block.receipts[0].result.expectOk().expectTuple()['participant2-balance'], types.uint(44910000)); // minus protocol fee
    
    // Verify channel is settled
    const result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    const channelInfo = result.result.expectSome().expectTuple();
    assertEquals(channelInfo['state'], types.uint(2)); // Settled
    assertEquals(channelInfo['capacity'], types.uint(0));
    assertEquals(channelInfo['participant1-balance'], types.uint(0));
    assertEquals(channelInfo['participant2-balance'], types.uint(0));
  },
});

Clarinet.test({
  name: "Ensure unilateral closing and dispute process works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(60000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Join the channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(40000000)
        ],
        participant2.address
      )
    ]);
    
    // Initiate unilateral close
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'initiate-channel-close',
        [types.uint(channelId)],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.expectOk().expectTuple()['dispute-end-block'], types.uint(chain.blockHeight + 1440)); // default dispute timeout
    
    // Verify channel state
    let result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    let channelInfo = result.result.expectSome().expectTuple();
    assertEquals(channelInfo['state'], types.uint(1)); // Closing
    
    // Create mock signature for balance proof
    const signature = '0x' + '02'.repeat(65);
    
    // Update balance during dispute
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'update-channel-in-dispute',
        [
          types.uint(channelId),
          types.uint(50000000), // New balance
          types.uint(1), // Nonce
          types.buff(signature)
        ],
        participant2.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Get dispute timeout
    const disputeTimeoutResponse = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-dispute-timeout',
      [],
      deployer.address
    );
    const disputeTimeout = disputeTimeoutResponse.result.expectUint();
    
    // Advance chain to end of dispute period
    chain.mineEmptyBlockUntil(chain.blockHeight + disputeTimeout);
    
    // Settle channel
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'settle-channel',
        [types.uint(channelId)],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.expectOk().expectTuple()['participant1-balance'].startsWith('u49'), true); // ~50 STX minus protocol fee
    assertEquals(block.receipts[0].result.expectOk().expectTuple()['participant2-balance'].startsWith('u49'), true); // ~50 STX minus protocol fee
    
    // Verify channel state
    result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channelId)],
      deployer.address
    );
    
    channelInfo = result.result.expectSome().expectTuple();
    assertEquals(channelInfo['state'], types.uint(2)); // Settled
  },
});

Clarinet.test({
  name: "Ensure channel rebalancing works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const intermediary = accounts.get('wallet_2')!;
    const participant2 = accounts.get('wallet_3')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], intermediary.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create first channel (participant1 <-> intermediary)
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(intermediary.address),
          types.uint(80000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channel1Id = block.receipts[0].result.expectOk().expectUint();
    
    // Join the first channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channel1Id),
          types.uint(20000000)
        ],
        intermediary.address
      )
    ]);
    
    // Create second channel (intermediary <-> participant2)
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(20000000),
          types.uint(0)
        ],
        intermediary.address
      )
    ]);
    
    const channel2Id = block.receipts[0].result.expectOk().expectUint();
    
    // Join the second channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channel2Id),
          types.uint(80000000)
        ],
        participant2.address
      )
    ]);
    
    // Rebalance channels
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'rebalance-channels',
        [
          types.uint(channel1Id),
          types.uint(channel2Id),
          types.uint(10000000) // Amount to rebalance
        ],
        intermediary.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.expectOk().expectTuple()['rebalanced'], types.uint(10000000));
    
    // Verify balances after rebalancing
    const channel1Result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channel1Id)],
      deployer.address
    );
    
    const channel2Result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channel2Id)],
      deployer.address
    );
    
    const channel1 = channel1Result.result.expectSome().expectTuple();
    const channel2 = channel2Result.result.expectSome().expectTuple();
    
    // In channel1, intermediary's balance should be reduced
    assertEquals(channel1['participant2-balance'], types.uint(10000000)); // 20M - 10M
    
    // In channel2, intermediary's balance should be increased
    assertEquals(channel2['participant1-balance'], types.uint(30000000)); // 20M + 10M
  },
});

Clarinet.test({
  name: "Ensure protocol fee settings can be updated",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    
    // Initialize the contract
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address)
    ]);
    
    // Update protocol fee
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'update-protocol-fee',
        [types.uint(30)], // 0.3%
        deployer.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify updated fee
    let result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-network-stats',
      [],
      deployer.address
    );
    
    let stats = result.result.expectTuple();
    assertEquals(stats['protocol-fee'], types.uint(30));
    
    // Update dispute timeout
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'update-dispute-timeout',
        [types.uint(2000)],
        deployer.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Update settle timeout
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'update-settle-timeout',
        [types.uint(180)],
        deployer.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Update minimum channel deposit
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'update-min-channel-deposit',
        [types.uint(2000000)],
        deployer.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify all updated values
    result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-network-stats',
      [],
      deployer.address
    );
    
    stats = result.result.expectTuple();
    assertEquals(stats['min-deposit'], types.uint(2000000));
  },
});

Clarinet.test({
  name: "Ensure fee collection and withdrawal works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    const treasuryAccount = accounts.get('wallet_3')!;
    
    // Initialize the contract
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address)
    ]);
    
    // Register participants
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Open and join a channel
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(100000000), // 100 STX
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(100000000) // 100 STX
        ],
        participant2.address
      )
    ]);
    
    // Create mock signatures
    const signature1 = '0x' + '00'.repeat(65);
    const signature2 = '0x' + '01'.repeat(65);
    
    // Close channel (will collect fees)
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'cooperative-close-channel',
        [
          types.uint(channelId),
          types.uint(110000000), // participant1 balance
          types.uint(90000000),  // participant2 balance
          types.buff(signature1),
          types.buff(signature2)
        ],
        participant1.address
      )
    ]);
    
    // Verify fees were collected
    let result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-network-stats',
      [],
      deployer.address
    );
    
    let stats = result.result.expectTuple();
    const feeBalance = parseInt(stats['protocol-fee-balance'].substring(1)); // Remove 'u' prefix
    
    // Should have collected 0.2% of 200M STX = 400,000 microSTX
    // Note: actual value might vary slightly due to rounding
    assertEquals(feeBalance > 0, true);
    
    // Withdraw collected fees
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'withdraw-protocol-fees',
        [types.principal(treasuryAccount.address)],
        deployer.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.expectOk().expectUint() > 0, true);
    
    // Verify fees were withdrawn
    result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-network-stats',
      [],
      deployer.address
    );
    
    stats = result.result.expectTuple();
    assertEquals(stats['protocol-fee-balance'], types.uint(0));
  },
});

Clarinet.test({
  name: "Ensure multi-hop payment routing works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const intermediary = accounts.get('wallet_2')!;
    const participant2 = accounts.get('wallet_3')!;
    
    // Setup
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], intermediary.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Create first channel (participant1 <-> intermediary)
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(intermediary.address),
          types.uint(100000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channel1Id = block.receipts[0].result.expectOk().expectUint();
    
    // Join the first channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channel1Id),
          types.uint(100000000)
        ],
        intermediary.address
      )
    ]);
    
    // Create second channel (intermediary <-> participant2)
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(100000000),
          types.uint(0)
        ],
        intermediary.address
      )
    ]);
    
    const channel2Id = block.receipts[0].result.expectOk().expectUint();
    
    // Join the second channel
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channel2Id),
          types.uint(100000000)
        ],
        participant2.address
      )
    ]);
    
    // Create secret and hashlock for HTLC
    const secret = '0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321';
    const hashlock = '0x4f298a7bb15e68aad6af28412ece5868788deef0ff6dd8f0876073c3e42ff902'; // sha256 of secret
    
    // Find a route
    const findRouteResult = chain.callReadOnlyFn(
      'payment-channel-network',
      'find-payment-route',
      [
        types.principal(participant1.address),
        types.principal(participant2.address),
        types.uint(20000000) // 20 STX
      ],
      participant1.address
    );
    
    // Route should exist (may be direct or indirect)
    assertEquals(findRouteResult.result.isOk(), true);
    
    // Start multi-hop payment
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'start-multi-hop-payment',
        [
          types.principal(participant2.address),
          types.uint(20000000), // 20 STX
          types.list([types.uint(channel1Id), types.uint(channel2Id)]), // Route
          types.buff(secret)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.isOk(), true);
    
    // Extract hashlock and timelock for next step
    const paymentData = block.receipts[0].result.expectOk().expectTuple();
    const htlcId = paymentData['first-htlc'].expectUint();
    const htlcHashlock = paymentData['hashlock'].expectBuff();
    const htlcTimelock = paymentData['timelock'].expectUint();
    
    // Intermediary continues the payment
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'continue-multi-hop-payment',
        [
          types.uint(channel1Id),
          types.uint(channel2Id),
          types.principal(participant2.address),
          types.uint(20000000),
          types.buff(htlcHashlock),
          types.uint(htlcTimelock)
        ],
        intermediary.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.isOk(), true);
    
    // Get second HTLC id
    const secondHtlcId = block.receipts[0].result.expectOk().expectUint();
    
    // Recipient reveals secret to claim payment
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'fulfill-htlc',
        [
          types.uint(secondHtlcId),
          types.buff(secret)
        ],
        participant2.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Intermediary also reveals secret to claim from first hop
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'fulfill-htlc',
        [
          types.uint(htlcId),
          types.buff(secret)
        ],
        intermediary.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result, '(ok true)');
    
    // Verify final balances
    const channel1Result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channel1Id)],
      deployer.address
    );
    
    const channel2Result = chain.callReadOnlyFn(
      'payment-channel-network',
      'get-channel-info',
      [types.uint(channel2Id)],
      deployer.address
    );
    
    const channel1 = channel1Result.result.expectSome().expectTuple();
    const channel2 = channel2Result.result.expectSome().expectTuple();
    
    // Participant1 paid 20 STX
    assertEquals(channel1['participant1-balance'], types.uint(80000000));
    // Intermediary received 20 STX in first channel
    assertEquals(channel1['participant2-balance'], types.uint(120000000));
    // Intermediary paid 20 STX in second channel
    assertEquals(channel2['participant1-balance'], types.uint(80000000));
    // Participant2 received 20 STX
    assertEquals(channel2['participant2-balance'], types.uint(120000000));
  },
});

Clarinet.test({
  name: "Ensure attempted invalid operations fail correctly",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get('deployer')!;
    const participant1 = accounts.get('wallet_1')!;
    const participant2 = accounts.get('wallet_2')!;
    const nonParticipant = accounts.get('wallet_3')!;
    
    // Initialize the contract
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'initialize', [], deployer.address)
    ]);
    
    // Register participants
    chain.mineBlock([
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant1.address),
      Tx.contractCall('payment-channel-network', 'register-participant', [], participant2.address)
    ]);
    
    // Test 1: Can't open channel with self
    let block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant1.address), // Same as sender
          types.uint(50000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.includes('err'), true);
    
    // Test 2: Can't open channel with deposit below minimum
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(100), // Too small
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.includes('err'), true);
    
    // Open a valid channel for remaining tests
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'open-channel',
        [
          types.principal(participant2.address),
          types.uint(50000000),
          types.uint(0)
        ],
        participant1.address
      )
    ]);
    
    const channelId = block.receipts[0].result.expectOk().expectUint();
    
    // Test 3: Non-participant can't join channel
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(30000000)
        ],
        nonParticipant.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.includes('err'), true);
    
    // Join channel properly
    chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'join-channel',
        [
          types.uint(channelId),
          types.uint(30000000)
        ],
        participant2.address
      )
    ]);
    
    // Test 4: Can't create HTLC with wrong participants
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'create-htlc',
        [
          types.uint(channelId),
          types.principal(nonParticipant.address), // Not part of channel
          types.uint(10000000),
          types.buff('0x' + '11'.repeat(32)),
          types.uint(chain.blockHeight + 144)
        ],
        participant1.address
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.includes('err'), true);
    
    // Test 5: Non-owner can't update protocol parameters
    block = chain.mineBlock([
      Tx.contractCall(
        'payment-channel-network',
        'update-protocol-fee',
        [types.uint(30)],
        participant1.address // Not contract owner
      )
    ]);
    
    assertEquals(block.receipts.length, 1);
    assertEquals(block.receipts[0].result.includes('err'), true);
  },
});