import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';

const PredictionMarketSimulator = () => {
  // Initial parameters
  const [initialLiquidity, setInitialLiquidity] = useState(75);
  const [feePercentage, setFeePercentage] = useState(5);
  const [betSize, setBetSize] = useState(10);
  
  // Market state
  const [liquidityOption1, setLiquidityOption1] = useState(initialLiquidity); // Yes (X)
  const [liquidityOption2, setLiquidityOption2] = useState(initialLiquidity); // No (Y)
  const [totalBetsOption1, setTotalBetsOption1] = useState(0);
  const [totalBetsOption2, setTotalBetsOption2] = useState(0);
  const [reserveX, setReserveX] = useState(0); // Reserve for Option 1
  const [reserveY, setReserveY] = useState(0); // Reserve for Option 2
  const [betHistory, setBetHistory] = useState([]);
  const [chartData, setChartData] = useState([]);
  const [activeBets, setActiveBets] = useState([]); // Track active bets for cashout
  
  const constantK = initialLiquidity * initialLiquidity;
  
  // Reset the simulation
  const resetSimulation = () => {
    setLiquidityOption1(initialLiquidity);
    setLiquidityOption2(initialLiquidity);
    setTotalBetsOption1(0);
    setTotalBetsOption2(0);
    setReserveX(0);
    setReserveY(0);
    setBetHistory([]);
    setActiveBets([]);
    
    // Initialize chart data
    setChartData([{
      name: 'Initial',
      liquidityOption1: initialLiquidity,
      liquidityOption2: initialLiquidity,
      reserveX: 0,
      reserveY: 0,
      oddsOption1: 2,
      oddsOption2: 2
    }]);
  };
  
  // Calculate display odds (Price 1 and Price 2 in Excel)
  const calculateDisplayOdds = (liq1, liq2) => {
    const totalLiquidity = liq1 + liq2;
    return {
      oddsOption1: totalLiquidity / liq1,
      oddsOption2: totalLiquidity / liq2
    };
  };
  
  // Calculate excess (columns G and H in Excel)
  const calculateExcess = () => {
    const excess1 = totalBetsOption1 - totalBetsOption2;
    const excess2 = totalBetsOption2 - totalBetsOption1;
    return { excess1, excess2 };
  };
  
  // Place a bet on Option 1 (Yes)
  const betOnOption1 = () => {
    // Update total bets
    const newTotalBetsOption1 = totalBetsOption1 + betSize;
    setTotalBetsOption1(newTotalBetsOption1);
    
    // Calculate excess
    const { excess1, excess2 } = calculateExcess();
    const newExcess1 = excess1 + betSize;
    const newExcess2 = excess2 - betSize;
    
    // Update liquidities according to Excel formula
    let newLiquidityOption1, newLiquidityOption2, resChangeX, resChangeY;
    
    // For Yes bets, if No has excess (excess1 < 0), scale the bet
    if (excess1 < 0) {
      // Scale the bet by reserveX / |excess1|
      const scaleFactor = reserveX / Math.abs(excess1);
      const scaledBet = betSize * scaleFactor;
      
      newLiquidityOption1 = liquidityOption1 + scaledBet;
      newLiquidityOption2 = constantK / newLiquidityOption1;
    } else {
      // Standard formula when Yes has no excess or positive excess
      newLiquidityOption1 = liquidityOption1 + betSize;
      newLiquidityOption2 = constantK / newLiquidityOption1;
    }
    
    // Calculate new reserves according to Excel formula
    // Reserve X = max(0, initialLiquidity - newLiquidityOption1)
    // Reserve Y = max(0, initialLiquidity - newLiquidityOption2)
    const newReserveX = newLiquidityOption1 >= initialLiquidity ? 0 : initialLiquidity - newLiquidityOption1;
    const newReserveY = newLiquidityOption2 >= initialLiquidity ? 0 : initialLiquidity - newLiquidityOption2;
    
    // Calculate reserve changes
    resChangeX = reserveX - newReserveX;
    resChangeY = reserveY - newReserveY;
    
    // Calculate extraction and locked odds
    const extractedFromOption2 = liquidityOption2 - newLiquidityOption2;
    const extractionRatio = extractedFromOption2 / betSize;
    const lockedOdds = 1 + extractionRatio * (1 - (feePercentage / 100));
    
    // Calculate potential payout and fees
    const potentialPayout = betSize * lockedOdds;
    const fees = extractedFromOption2 * (feePercentage / 100);
    
    // Update state
    setLiquidityOption1(newLiquidityOption1);
    setLiquidityOption2(newLiquidityOption2);
    setReserveX(newReserveX);
    setReserveY(newReserveY);
    
    // Add to bet history
    const timestamp = new Date().toLocaleTimeString();
    const betId = betHistory.length + 1;
    const newBet = {
      id: betId,
      time: timestamp,
      option: 'Yes',
      amount: betSize,
      totalBets1: newTotalBetsOption1,
      totalBets2: totalBetsOption2,
      excess1: newExcess1,
      excess2: newExcess2,
      liq1: newLiquidityOption1,
      liq2: newLiquidityOption2,
      resChangeX: resChangeX,
      resChangeY: resChangeY,
      reserveX: newReserveX,
      reserveY: newReserveY,
      lockedOdds: lockedOdds.toFixed(4),
      potentialPayout: potentialPayout.toFixed(2),
      extractedAmount: extractedFromOption2.toFixed(2),
      fees: fees.toFixed(2),
      status: 'active'
    };
    
    setBetHistory([...betHistory, newBet]);
    
    // Add to active bets
    setActiveBets([...activeBets, {
      id: betId,
      option: 'Yes',
      amount: betSize,
      lockedOdds: lockedOdds,
      potentialPayout: potentialPayout,
      timestamp: timestamp
    }]);
    
    // Update chart data
    updateChartData(newLiquidityOption1, newLiquidityOption2, newReserveX, newReserveY);
  };
  
  // Place a bet on Option 2 (No)
  const betOnOption2 = () => {
    // Update total bets
    const newTotalBetsOption2 = totalBetsOption2 + betSize;
    setTotalBetsOption2(newTotalBetsOption2);
    
    // Calculate excess
    const { excess1, excess2 } = calculateExcess();
    const newExcess1 = excess1 - betSize;
    const newExcess2 = excess2 + betSize;
    
    // Update liquidities according to Excel formula
    let newLiquidityOption1, newLiquidityOption2, resChangeX, resChangeY;
    
    // For No bets, if Yes has excess (excess1 > 0), scale the bet
    if (excess1 > 0) {
      // Scale the bet by reserveY / excess1
      const scaleFactor = reserveY / excess1;
      const scaledBet = betSize * scaleFactor;
      
      newLiquidityOption2 = liquidityOption2 + scaledBet;
      newLiquidityOption1 = constantK / newLiquidityOption2;
    } else {
      // Standard formula when No has no excess or positive excess
      newLiquidityOption2 = liquidityOption2 + betSize;
      newLiquidityOption1 = constantK / newLiquidityOption2;
    }
    
    // Calculate new reserves according to Excel formula
    // Reserve X = max(0, initialLiquidity - newLiquidityOption1)
    // Reserve Y = max(0, initialLiquidity - newLiquidityOption2)
    const newReserveX = newLiquidityOption1 >= initialLiquidity ? 0 : initialLiquidity - newLiquidityOption1;
    const newReserveY = newLiquidityOption2 >= initialLiquidity ? 0 : initialLiquidity - newLiquidityOption2;
    
    // Calculate reserve changes
    resChangeX = reserveX - newReserveX;
    resChangeY = reserveY - newReserveY;
    
    // Calculate extraction and locked odds
    const extractedFromOption1 = liquidityOption1 - newLiquidityOption1;
    const extractionRatio = extractedFromOption1 / betSize;
    const lockedOdds = 1 + extractionRatio * (1 - (feePercentage / 100));
    
    // Calculate potential payout and fees
    const potentialPayout = betSize * lockedOdds;
    const fees = extractedFromOption1 * (feePercentage / 100);
    
    // Update state
    setLiquidityOption1(newLiquidityOption1);
    setLiquidityOption2(newLiquidityOption2);
    setReserveX(newReserveX);
    setReserveY(newReserveY);
    
    // Add to bet history
    const timestamp = new Date().toLocaleTimeString();
    const betId = betHistory.length + 1;
    const newBet = {
      id: betId,
      time: timestamp,
      option: 'No',
      amount: betSize,
      totalBets1: totalBetsOption1,
      totalBets2: newTotalBetsOption2,
      excess1: newExcess1,
      excess2: newExcess2,
      liq1: newLiquidityOption1,
      liq2: newLiquidityOption2,
      resChangeX: resChangeX,
      resChangeY: resChangeY,
      reserveX: newReserveX,
      reserveY: newReserveY,
      lockedOdds: lockedOdds.toFixed(4),
      potentialPayout: potentialPayout.toFixed(2),
      extractedAmount: extractedFromOption1.toFixed(2),
      fees: fees.toFixed(2),
      status: 'active'
    };
    
    setBetHistory([...betHistory, newBet]);
    
    // Add to active bets
    setActiveBets([...activeBets, {
      id: betId,
      option: 'No',
      amount: betSize,
      lockedOdds: lockedOdds,
      potentialPayout: potentialPayout,
      timestamp: timestamp
    }]);
    
    // Update chart data
    updateChartData(newLiquidityOption1, newLiquidityOption2, newReserveX, newReserveY);
  };
  
  // Early Exit (Cashout) Implementation
  const cashoutBet = (betId) => {
    // Find the bet in active bets
    const betIndex = activeBets.findIndex(bet => bet.id === betId);
    if (betIndex === -1) return;
    
    const bet = activeBets[betIndex];
    const { option, amount, lockedOdds, potentialPayout } = bet;
    
    // Calculate profit portion (potential payout - original bet)
    const profitPortion = potentialPayout - amount;
    
    let cashoutAmount = 0;
    let newLiquidityOption1 = liquidityOption1;
    let newLiquidityOption2 = liquidityOption2;
    let newReserveX = reserveX;
    let newReserveY = reserveY;
    let newTotalBetsOption1 = totalBetsOption1;
    let newTotalBetsOption2 = totalBetsOption2;
    
    // Step 1: Simulate the hypothetical opposite bet
    if (option === 'Yes') {
      // For Yes bets, simulate betting the profit on No
      // First, calculate what happens to pools if we add profit to No side
      const simulatedLiquidityOption2 = liquidityOption2 + profitPortion;
      const simulatedLiquidityOption1 = constantK / simulatedLiquidityOption2;
      
      // Cashout amount is the reduction in Option 1 liquidity
      cashoutAmount = liquidityOption1 - simulatedLiquidityOption1;
      
      // Remove original bet and add simulated bet to totals
      newTotalBetsOption1 = totalBetsOption1 - amount;
      newTotalBetsOption2 = totalBetsOption2 + profitPortion;
      
      // Update pool state
      newLiquidityOption1 = simulatedLiquidityOption1;
      newLiquidityOption2 = simulatedLiquidityOption2;
    } else {
      // For No bets, simulate betting the profit on Yes
      const simulatedLiquidityOption1 = liquidityOption1 + profitPortion;
      const simulatedLiquidityOption2 = constantK / simulatedLiquidityOption1;
      
      // Cashout amount is the reduction in Option 2 liquidity
      cashoutAmount = liquidityOption2 - simulatedLiquidityOption2;
      
      // Remove original bet and add simulated bet to totals
      newTotalBetsOption2 = totalBetsOption2 - amount;
      newTotalBetsOption1 = totalBetsOption1 + profitPortion;
      
      // Update pool state
      newLiquidityOption1 = simulatedLiquidityOption1;
      newLiquidityOption2 = simulatedLiquidityOption2;
    }
    
    // Deduct fees from the cashout (fee is only applied to the profit portion)
    const profitInCashout = Math.max(0, cashoutAmount - amount);
    const fees = profitInCashout * (feePercentage / 100);
    cashoutAmount = cashoutAmount - fees;
    
    // Ensure cashout amount is positive
    cashoutAmount = Math.max(cashoutAmount, 0);
    
    // Update reserves
    newReserveX = newLiquidityOption1 >= initialLiquidity ? 0 : initialLiquidity - newLiquidityOption1;
    newReserveY = newLiquidityOption2 >= initialLiquidity ? 0 : initialLiquidity - newLiquidityOption2;
    
    // Ensure cashout amount is positive (should always be the case in theory, but added as a safety check)
    cashoutAmount = Math.max(cashoutAmount, 0);
    
    // Update bet history
    const updatedHistory = betHistory.map(historyBet => {
      if (historyBet.id === betId) {
        return {
          ...historyBet,
          status: 'cashed out',
          cashoutAmount: cashoutAmount.toFixed(2),
          cashoutTime: new Date().toLocaleTimeString()
        };
      }
      return historyBet;
    });
    
    // Update active bets (remove the cashed out bet)
    const updatedActiveBets = activeBets.filter(activeBet => activeBet.id !== betId);
    
    // Update state
    setBetHistory(updatedHistory);
    setActiveBets(updatedActiveBets);
    setLiquidityOption1(newLiquidityOption1);
    setLiquidityOption2(newLiquidityOption2);
    setReserveX(newReserveX);
    setReserveY(newReserveY);
    setTotalBetsOption1(newTotalBetsOption1);
    setTotalBetsOption2(newTotalBetsOption2);
    
    // Update chart data
    updateChartData(newLiquidityOption1, newLiquidityOption2, newReserveX, newReserveY);
    
    // Return cashout amount for UI
    return cashoutAmount;
  };
  
  // Update chart data
  const updateChartData = (liq1, liq2, resX, resY) => {
    const displayOdds = calculateDisplayOdds(liq1, liq2);
    const newDataPoint = {
      name: `Bet ${betHistory.length + 1}`,
      liquidityOption1: liq1,
      liquidityOption2: liq2,
      reserveX: resX,
      reserveY: resY,
      oddsOption1: displayOdds.oddsOption1,
      oddsOption2: displayOdds.oddsOption2
    };
    
    setChartData([...chartData, newDataPoint]);
  };
  
  // Reset when params change
  useEffect(() => {
    resetSimulation();
  }, [initialLiquidity, feePercentage]);
  
  // Calculate current display odds
  const currentOdds = calculateDisplayOdds(liquidityOption1, liquidityOption2);
  
  // Reproduce the example sequence
  const runExampleSequence = () => {
    resetSimulation();
    
    // First 5 bets on Yes
    for (let i = 0; i < 5; i++) {
      setTimeout(() => {
        betOnOption1();
      }, i * 300);
    }
    
    // Then 5 bets on No
    for (let i = 0; i < 5; i++) {
      setTimeout(() => {
        betOnOption2();
      }, 1500 + i * 300);
    }
  };
  
  // Calculate excess
  const { excess1, excess2 } = calculateExcess();
  
  // Calculate potential cashout values for each active bet
  const calculateCashoutAmounts = () => {
    return activeBets.map(bet => {
      const { option, amount, lockedOdds, potentialPayout } = bet;
      const profitPortion = potentialPayout - amount;
      
      let simulatedCashoutAmount = 0;
      
      if (option === 'Yes') {
        // For Yes bets, simulate betting the profit on No
        const simulatedLiquidityOption2 = liquidityOption2 + profitPortion;
        const simulatedLiquidityOption1 = constantK / simulatedLiquidityOption2;
        simulatedCashoutAmount = liquidityOption1 - simulatedLiquidityOption1;
      } else {
        // For No bets, simulate betting the profit on Yes
        const simulatedLiquidityOption1 = liquidityOption1 + profitPortion;
        const simulatedLiquidityOption2 = constantK / simulatedLiquidityOption1;
        simulatedCashoutAmount = liquidityOption2 - simulatedLiquidityOption2;
      }
      
      // Apply fees to profit portion
      const profitInCashout = Math.max(0, simulatedCashoutAmount - amount);
      const fees = profitInCashout * (feePercentage / 100);
      simulatedCashoutAmount = simulatedCashoutAmount - fees;
      
      return {
        betId: bet.id,
        cashoutAmount: Math.max(simulatedCashoutAmount, 0).toFixed(2)
      };
    });
  };
  
  const cashoutValues = calculateCashoutAmounts();
  
  return (
    <div className="p-4">
      <h1 className="text-2xl font-bold mb-2">Prediction Market Simulator with Cashout</h1>
      <div className="text-sm text-gray-600 mb-4">
        Implementation matching Excel's reserve-based formula system with early exit feature
      </div>
      
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
        <div className="bg-gray-100 p-4 rounded">
          <h2 className="text-lg font-semibold mb-2">Market Parameters</h2>
          <div className="mb-3">
            <label className="block text-sm font-medium mb-1">Initial Liquidity:</label>
            <input
              type="number"
              value={initialLiquidity}
              onChange={(e) => setInitialLiquidity(Number(e.target.value))}
              className="w-full p-2 border rounded"
              min="10"
            />
          </div>
          <div className="mb-3">
            <label className="block text-sm font-medium mb-1">Fee Percentage:</label>
            <input
              type="number"
              value={feePercentage}
              onChange={(e) => setFeePercentage(Number(e.target.value))}
              className="w-full p-2 border rounded"
              min="0"
              max="10"
              step="0.5"
            />
          </div>
          <div className="mb-3">
            <label className="block text-sm font-medium mb-1">Bet Size:</label>
            <input
              type="number"
              value={betSize}
              onChange={(e) => setBetSize(Number(e.target.value))}
              className="w-full p-2 border rounded"
              min="1"
            />
          </div>
        </div>
        
        <div className="bg-gray-100 p-4 rounded">
          <h2 className="text-lg font-semibold mb-2">Current Market Status</h2>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Yes Liquidity (X):</span>
              <span className="font-medium">{liquidityOption1.toFixed(2)}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>No Liquidity (Y):</span>
              <span className="font-medium">{liquidityOption2.toFixed(2)}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Total Liquidity:</span>
              <span className="font-medium">{(liquidityOption1 + liquidityOption2).toFixed(2)}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Reserve X:</span>
              <span className="font-medium">{reserveX.toFixed(2)}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Reserve Y:</span>
              <span className="font-medium">{reserveY.toFixed(2)}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Total Bets Yes:</span>
              <span className="font-medium">{totalBetsOption1}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Total Bets No:</span>
              <span className="font-medium">{totalBetsOption2}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Excess Yes:</span>
              <span className={`font-medium ${excess1 > 0 ? 'text-blue-600' : ''}`}>
                {excess1}
              </span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Excess No:</span>
              <span className={`font-medium ${excess2 > 0 ? 'text-green-600' : ''}`}>
                {excess2}
              </span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Constant K:</span>
              <span className="font-medium">{constantK.toFixed(2)}</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>Yes Display Odds:</span>
              <span className="font-medium">{currentOdds.oddsOption1.toFixed(4)}×</span>
            </div>
          </div>
          <div className="mb-2">
            <div className="flex justify-between">
              <span>No Display Odds:</span>
              <span className="font-medium">{currentOdds.oddsOption2.toFixed(4)}×</span>
            </div>
          </div>
        </div>
        
        <div className="bg-gray-100 p-4 rounded">
          <h2 className="text-lg font-semibold mb-2">Actions</h2>
          <div className="grid grid-cols-2 gap-2 mb-4">
            <button
              onClick={betOnOption1}
              className="bg-blue-500 text-white py-2 px-4 rounded hover:bg-blue-600"
            >
              Bet on Yes
            </button>
            <button
              onClick={betOnOption2}
              className="bg-green-500 text-white py-2 px-4 rounded hover:bg-green-600"
            >
              Bet on No
            </button>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <button
              onClick={resetSimulation}
              className="bg-red-500 text-white py-2 px-4 rounded hover:bg-red-600"
            >
              Reset Market
            </button>
            <button
              onClick={runExampleSequence}
              className="bg-purple-500 text-white py-2 px-4 rounded hover:bg-purple-600"
            >
              Run Example
            </button>
          </div>
        </div>
      </div>
      
      <div className="mb-6 bg-white p-6 border rounded-lg shadow-sm">
        <div className="grid grid-cols-2 gap-8">
          <div className="text-center">
            <h2 className="text-xl font-bold text-blue-700 mb-1">Yes Odds</h2>
            <div className="text-4xl font-bold">{currentOdds.oddsOption1.toFixed(4)}×</div>
          </div>
          <div className="text-center">
            <h2 className="text-xl font-bold text-green-700 mb-1">No Odds</h2>
            <div className="text-4xl font-bold">{currentOdds.oddsOption2.toFixed(4)}×</div>
          </div>
        </div>
      </div>
      
      {/* Active Bets with Cashout Options */}
      {activeBets.length > 0 && (
        <div className="mb-6">
          <h2 className="text-lg font-semibold mb-2">Active Bets</h2>
          <div className="bg-white border rounded overflow-auto">
            <table className="min-w-full divide-y divide-gray-200">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Bet #</th>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Option</th>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Amount</th>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Locked Odds</th>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Potential Payout</th>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Est. Cashout Value</th>
                  <th className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Action</th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {activeBets.map((bet) => {
                  const cashoutInfo = cashoutValues.find(c => c.betId === bet.id);
                  const cashoutAmount = cashoutInfo ? cashoutInfo.cashoutAmount : '0.00';
                  
                  return (
                    <tr key={bet.id}>
                      <td className="px-3 py-4 whitespace-nowrap text-sm font-medium text-gray-900">{bet.id}</td>
                      <td className="px-3 py-4 whitespace-nowrap text-sm text-gray-500">
                        <span className={`px-2 py-1 inline-flex text-xs leading-5 font-semibold rounded-full ${bet.option === 'Yes' ? 'bg-blue-100 text-blue-800' : 'bg-green-100 text-green-800'}`}>
                          {bet.option}
                        </span>
                      </td>
                      <td className="px-3 py-4 whitespace-nowrap text-sm text-gray-500">{bet.amount.toFixed(2)}</td>
                      <td className="px-3 py-4 whitespace-nowrap text-sm text-gray-500">{bet.lockedOdds.toFixed(4)}×</td>
                      <td className="px-3 py-4 whitespace-nowrap text-sm text-gray-500">{bet.potentialPayout.toFixed(2)}</td>
                      <td className="px-3 py-4 whitespace-nowrap text-sm text-gray-500">
                        <span className={parseFloat(cashoutAmount) >= bet.amount ? 'text-green-600 font-semibold' : 'text-red-600 font-semibold'}>
                          {cashoutAmount}
                        </span>
                      </td>
                      <td className="px-3 py-4 whitespace-nowrap text-sm text-gray-500">
                        <button
                          onClick={() => cashoutBet(bet.id)}
                          className="bg-yellow-500 hover:bg-yellow-600 text-white py-1 px-3 rounded text-xs"
                        >
                          Cash Out
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
      
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
        <div>
          <h2 className="text-lg font-semibold mb-2">Odds Chart</h2>
          <div className="h-64 bg-white p-2 border rounded">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={chartData}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="name" />
                <YAxis />
                <Tooltip />
                <Legend />
                <Line type="monotone" dataKey="oddsOption1" name="Yes Odds" stroke="#3b82f6" />
                <Line type="monotone" dataKey="oddsOption2" name="No Odds" stroke="#10b981" />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>
        
        <div>
          <h2 className="text-lg font-semibold mb-2">Liquidity & Reserve Chart</h2>
          <div className="h-64 bg-white p-2 border rounded">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={chartData}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="name" />
                <YAxis />
                <Tooltip />
                <Legend />
                <Line type="monotone" dataKey="liquidityOption1" name="Yes Liquidity" stroke="#3b82f6" />
                <Line type="monotone" dataKey="liquidityOption2" name="No Liquidity" stroke="#10b981" />
                <Line type="monotone" dataKey="reserveX" name="Reserve X" stroke="#f59e0b" />
                <Line type="monotone" dataKey="reserveY" name="Reserve Y" stroke="#ef4444" />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>
      
      <div className="mb-6">
        <h2 className="text-lg font-semibold mb-2">Early Exit (Cashout) Mechanism</h2>
        <div className="bg-white p-4 border rounded">
          <h3 className="font-medium text-lg mb-2">How Cashout Works:</h3>
          <ol className="list-decimal pl-6 space-y-2">
            <li>The cashout process treats the user's locked payout as a hypothetical bet on the opposite side.</li>
            <li>For a Yes bet with bet amount B and locked odds O, the potential payout is P = B × O.</li>
            <li>When cashing out, we simulate placing a bet of (P - B) on the No side.</li>
            <li>The resulting change in the Yes pool becomes the cashout amount.</li>
            <li>The bet is removed from active bets, and market liquidity is updated accordingly.</li>
          </ol>
          
          <h3 className="font-medium text-lg mt-4">Cashout Value Calculation:</h3>
          <p className="mt-2">For a Yes bet:</p>
          <pre className="text-xs overflow-auto p-2 bg-gray-200 mt-1">
            simulatedLiquidityOption2 = liquidityOption2 + profitPortion
            simulatedLiquidityOption1 = constantK / simulatedLiquidityOption2
            cashoutAmount = liquidityOption1 - simulatedLiquidityOption1
          </pre>
          
          <p className="mt-2">For a No bet:</p>
          <pre className="text-xs overflow-auto p-2 bg-gray-200 mt-1">
            simulatedLiquidityOption1 = liquidityOption1 + profitPortion
            simulatedLiquidityOption2 = constantK / simulatedLiquidityOption1
            cashoutAmount = liquidityOption2 - simulatedLiquidityOption2
          </pre>
          
          <div className="mt-4 bg-yellow-50 border border-yellow-200 p-3 rounded">
            <p className="text-sm">
              <span className="font-semibold">Note:</span> The cashout value is dynamic and changes based on current market odds. If odds move in your favor, the cashout value increases. If odds move against you, the cashout value decreases.
            </p>
          </div>
        </div>
      </div>
      
      <div>
        <h2 className="text-lg font-semibold mb-2">Bet History</h2>
        <div className="bg-white border rounded overflow-auto">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Bet #</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Option</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Amount</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Status</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Locked Odds</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Potential Payout</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Cashout Amount</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Reserve X</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Reserve Y</th>
                <th className="px-2 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Extracted</th>
              </tr>
            </thead>
            <tbody className="bg-white divide-y divide-gray-200">
              {betHistory.length === 0 ? (
                <tr>
                  <td colSpan="10" className="px-2 py-4 text-center text-sm text-gray-500">No bets placed yet</td>
                </tr>
              ) : (
                betHistory.map(bet => (
                  <tr key={bet.id}>
                    <td className="px-2 py-4 whitespace-nowrap text-sm font-medium text-gray-900">{bet.id}</td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">
                      <span className={`px-2 py-1 inline-flex text-xs leading-5 font-semibold rounded-full ${bet.option === 'Yes' ? 'bg-blue-100 text-blue-800' : 'bg-green-100 text-green-800'}`}>
                        {bet.option}
                      </span>
                    </td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">{bet.amount}</td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">
                      <span className={`px-2 py-1 inline-flex text-xs leading-5 font-semibold rounded-full ${bet.status === 'active' ? 'bg-blue-100 text-blue-800' : 'bg-yellow-100 text-yellow-800'}`}>
                        {bet.status || 'active'}
                      </span>
                    </td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">{bet.lockedOdds}×</td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">{bet.potentialPayout}</td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">
                      {bet.cashoutAmount ? bet.cashoutAmount : '-'}
                    </td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">{parseFloat(bet.reserveX).toFixed(2)}</td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">{parseFloat(bet.reserveY).toFixed(2)}</td>
                    <td className="px-2 py-4 whitespace-nowrap text-sm text-gray-500">
                      {bet.option === 'Yes' ? bet.extractedAmount : bet.option === 'No' ? bet.extractedAmount : '-'}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

export default PredictionMarketSimulator;