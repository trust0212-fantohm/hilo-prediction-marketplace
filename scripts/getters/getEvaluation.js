import { ethers } from "ethers";
import { abi } from "./abi.js";

const contractAddress = "0xfcc41c158DFC4fbcF9bf8eDd126a5A65D110502F";
const rpcUrl = "https://erc20.hiloscan.io:8448";
const functionName = "getPoolEvaluationStatus";

const inputParams = {
  _poolId: 26,
};

console.log(inputParams);

const provider = new ethers.JsonRpcProvider(rpcUrl);
const contract = new ethers.Contract(contractAddress, abi, provider);

const functionAbi = abi.find((item) => item.name === functionName);
const inputArray = functionAbi.inputs.map((input) => inputParams[input.name]);
const result = await contract[functionName](...inputArray);

const namedResult = functionAbi.outputs.reduce((acc, output, index) => {
  acc[output.name || `output${index}`] = result[index];
  return acc;
}, {});

console.log(namedResult);