use poseidon::poseidon2::Poseidon2;

// Maximum Merkle tree depth (supports up to 2^10 = 1,024 participants)
global MAX_DEPTH: u32 = 10;

// Compute Poseidon2 hash of two Field elements
fn hash2(a: Field, b: Field) -> Field {
    Poseidon2::hash([a, b], 2)
}

// Compute Poseidon2 hash of a single Field element  
fn hash1(a: Field) -> Field {
    Poseidon2::hash([a], 1)
}

fn main(
    // PRIVATE INPUTS
    secret: Field,
    nullifier: Field,
    siblings: [Field; MAX_DEPTH],
    path_indices: [Field; MAX_DEPTH],  // 0 or 1 for each level
    recipient: Field,
    
    // PUBLIC INPUTS
    root: pub Field,
    nullifier_hash: pub Field,
    recipient_binding: pub Field,
    raffle_id: pub Field,
    winner_index: pub Field,
    tree_depth: pub Field
) {
    // Convert tree_depth to u32 for comparisons
    let depth = tree_depth as u32;
    assert(depth <= MAX_DEPTH);
    assert(depth > 0);
    
    // commitment = Poseidon2(secret, nullifier)
    let commitment = hash2(secret, nullifier);
    
    let computed_nullifier_hash = hash1(nullifier);
    assert(computed_nullifier_hash == nullifier_hash);
    
    let computed_recipient_binding = hash2(nullifier_hash, recipient);
    assert(computed_recipient_binding == recipient_binding);
    
    let mut reconstructed_index: Field = 0;
    let mut power_of_two: Field = 1;
    for i in 0..MAX_DEPTH {
        if i < depth {
            let bit = path_indices[i];
            // Ensure bit is 0 or 1
            assert(bit * (bit - 1) == 0);
            reconstructed_index = reconstructed_index + bit * power_of_two;
            power_of_two = power_of_two * 2;
        }
    }
    assert(reconstructed_index == winner_index);
    
    let mut current_hash = commitment;
    for i in 0..MAX_DEPTH {
        if i < depth {
            let sibling = siblings[i];
            let is_right = path_indices[i];
            
            let left = if is_right == 0 { current_hash } else { sibling };
            let right = if is_right == 0 { sibling } else { current_hash };
            
            current_hash = hash2(left, right);
        }
    }
    assert(current_hash == root);
    
    assert(raffle_id != 0);
}

#[test]
fn test_hash2() {
    let h = hash2(1, 2);
    assert(h != 0);
}

#[test]
fn test_hash1() {
    let h = hash1(42);
    assert(h != 0);
}

#[test]
fn test_simple_merkle_proof() {
    let secret: Field = 123;
    let nullifier: Field = 456;
    let commitment = hash2(secret, nullifier);
    
    let leaf1 = hash2(789, 101112);
    
    let computed_root = hash2(commitment, leaf1);
    
    let mut siblings: [Field; MAX_DEPTH] = [0; MAX_DEPTH];
    siblings[0] = leaf1;
    
    let path_indices: [Field; MAX_DEPTH] = [0; MAX_DEPTH];
  
    let mut current = commitment;
    let sibling = siblings[0];
    let is_right = path_indices[0];
    let left = if is_right == 0 { current } else { sibling };
    let right = if is_right == 0 { sibling } else { current };
    current = hash2(left, right);
    
    assert(current == computed_root);
}
