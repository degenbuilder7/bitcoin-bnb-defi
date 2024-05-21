// const fetchLatestBlock = () =>
//     fetch(`https://blockchain.info/q/latesthash?cors=true`)
//       .then(r => r.text());
  
//   const fetchMerkleRootAndTransactions = block =>
//     fetch(`https://blockchain.info/rawblock/${block}?cors=true`)
//       .then(r => r.json())
//       .then(d => [d.mrkl_root, d.tx.map(t => t.hash)]);
  
//   const random = arr =>
//     arr[Math.floor(Math.random() * arr.length)];
  
//   const toBytes = hex =>
//     hex.match(/../g).reduce((acc, hex) => [...acc, parseInt(hex, 16)], []);
  
//   const toHex = bytes =>
//     bytes.reduce((acc, bytes) => acc + bytes.toString(16).padStart(2, '0'), '');
  
//   const toPairs = arr =>
//     Array.from(Array(Math.ceil(arr.length / 2)), (_, i) => arr.slice(i * 2, i * 2 + 2));
  
//   const hashPair = (a, b = a) => {
//     const bytes = toBytes(`${b}${a}`).reverse();
//     const hashed = sha256.array(sha256.array(bytes));
//     return toHex(hashed.reverse());
//   };
  
//   const merkleProof = (txs, tx, proof = []) => {
//     if (txs.length === 1) {
//       return proof;
//     }
  
//     const tree = [];
  
//     toPairs(txs).forEach(pair => {
//       const hash = hashPair(...pair);
  
//       if (pair.includes(tx)) {
//         const idx = pair[0] === tx | 0;
//         proof.push([idx, pair[idx]]);
//         tx = hash;
//       }
  
//       tree.push(hash);
//     });
  
//     return merkleProof(tree, tx, proof);
//   };
  
//   const merkleProofRoot = (proof, tx) =>
//     proof.reduce((root, [idx, tx]) => idx ? hashPair(root, tx) : hashPair(tx, root), tx);
  
//   fetchLatestBlock()
//     .then(fetchMerkleRootAndTransactions)
//     .then(([root, txs]) => {
//       const tx = random(txs);
//       const proof = merkleProof(txs, tx);
  
//       const isValid = merkleProofRoot(proof, tx) === root;
//       console.log(isValid);
//     });