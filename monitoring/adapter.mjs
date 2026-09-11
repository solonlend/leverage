import {isLogRangeError} from './rpc.mjs';
const fn=(name,inputs,outputs)=>({type:'function',name,stateMutability:'view',inputs:inputs.map(type=>({type})),outputs:outputs.map(type=>({type}))});
export const badDebtEvent={type:'event',name:'BadDebt',inputs:[{name:'id',type:'uint256',indexed:true},{name:'debtId',type:'uint256',indexed:true},{name:'residualDebt',type:'uint256',indexed:false}]};
export const abi=[badDebtEvent,fn('latestRoundData',[],['uint80','int256','uint256','uint256','uint80']),fn('decimals',[],['uint8']),fn('nextPositionId',[],['uint256']),fn('LLTV',[],['uint256']),fn('ownerOf',['uint256'],['address']),fn('positionValue',['uint256'],['uint256']),fn('totalDebtInLoan',['uint256'],['uint256'])];
export function createChain(client,config) {
  const call=(address,functionName,args=[],blockNumber)=>client.readContract({address,abi,functionName,args,blockNumber});
  return {
    async feed(name) {
      const address=name==='ETH'?config.ethFeed:config.usdgFeed;
      const blockNumber=await client.getBlockNumber({cacheTime:0});
      const [round,decimals]=await Promise.all([call(address,'latestRoundData',[],blockNumber),call(address,'decimals',[],blockNumber)]);
      return {round,decimals};
    },
    head:()=>client.getBlockNumber({cacheTime:0}),
    blockHash:async blockNumber=>{const block=await client.getBlock({blockNumber});if(!block.hash)throw Error('missing hash');return block.hash;},
    async badDebt(fromBlock,toBlock) {
      const logs=[];let size=BigInt(config.logBlockRange??1000);
      for(let from=fromBlock;from<=toBlock;) {
        const to=from+size-1n<toBlock?from+size-1n:toBlock;
        try {
          logs.push(...await client.getLogs({address:config.vault,event:badDebtEvent,fromBlock:from,toBlock:to,strict:true}));
          from=to+1n;
        } catch(error) {
          if(!isLogRangeError(error)||size===1n)throw error;
          size=size/2n;
        }
      }
      return logs;
    },
    nextPositionId:()=>call(config.vault,'nextPositionId'),lltv:()=>call(config.vault,'LLTV'),
    async position(id) {
      const blockNumber=await client.getBlockNumber({cacheTime:0});
      const owner=await call(config.vault,'ownerOf',[id],blockNumber);
      if(owner.toLowerCase()==='0x'+'0'.repeat(40))return null;
      const [value,debt]=await Promise.all([call(config.vault,'positionValue',[id],blockNumber),call(config.vault,'totalDebtInLoan',[id],blockNumber)]);
      return {value,debt};
    },
  };
}
