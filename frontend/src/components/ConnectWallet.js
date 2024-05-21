import React from "react";
// import bmp from "bitcoin-merkle-proof";
import { NetworkErrorMessage } from "./NetworkErrorMessage";

export function ConnectWallet({ connectWallet, networkError, dismiss }) {
// build merkle proof object (block #681135 in testnet)
// var merkleProof = bmp.build({
//   hashes: [
//     new Buffer('52a893ef120d5e24aa38604ead9ada6628eea417df6d6096ef0dd7b73a89c0e9', 'hex'),
//     new Buffer('a76a1e1bffbbb254bd897e379298549eb8ff4aa57a4bb4c06637b36d76833207', 'hex'),
//     new Buffer('056b4e64697677788744a8ad23cc407cbc1c357ff889d9975edd431fb779466f', 'hex'),
//     new Buffer('3c51bfb4f9cdd2b8e3a5c47cb1b3bdbc8879a1c1b238d4123dcb572a00b2b80e', 'hex'),
//     new Buffer('d6d1f9ca0a4017050379a82ecccb050cf4218f2180087e9592110972a71e375c', 'hex')
//   ],
//   include: [
//     new Buffer('3c51bfb4f9cdd2b8e3a5c47cb1b3bdbc8879a1c1b238d4123dcb572a00b2b80e', 'hex'),
//     new Buffer('d6d1f9ca0a4017050379a82ecccb050cf4218f2180087e9592110972a71e375c', 'hex')
//   ]
// });

// console.log(merkleProof,"m proof")

  return (
    <div className="container">
      <div className="row justify-content-md-center">
        <div className="col-12 text-center">
          {/* Wallet network should be set to Localhost:8545. */}
          {networkError && (
            <NetworkErrorMessage 
              message={networkError} 
              dismiss={dismiss} 
            />
          )}
        </div>
        <div className="col-6 p-4 text-center">
          <p>Please connect to your wallet.</p>
          <button
            className="btn btn-warning"
            type="button"
            onClick={connectWallet}
          >
            Connect Wallet
          </button>
        </div>
      </div>
    </div>
  );
}
