package bench

import (
	"bytes"
	"math/big"
	"testing"

	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestUniArtifactsAndCalldata(t *testing.T) {
	managerArtifact, managerABI, err := loadUniArtifact("PoolManager")
	if err != nil {
		t.Fatal(err)
	}
	if len(ethcmn.FromHex(managerArtifact.Bytecode)) < 20_000 {
		t.Fatal("PoolManager artifact bytecode is unexpectedly small")
	}

	token := ethcmn.HexToAddress("0x1000000000000000000000000000000000000001")
	router := ethcmn.HexToAddress("0x2000000000000000000000000000000000000002")
	for _, contract := range []string{"PoolManager", "PoolModifyLiquidityTest", "PoolSwapTest", "AdventureToken"} {
		_, contractABI, err := loadUniArtifact(contract)
		if err != nil {
			t.Fatal(err)
		}
		constructorData, err := contractABI.Pack("", router)
		if err != nil {
			t.Fatalf("pack %s constructor: %v", contract, err)
		}
		if len(constructorData) != 32 {
			t.Fatalf("unexpected %s constructor length: %d", contract, len(constructorData))
		}
	}

	key := newUniPoolKey(token)
	sqrtPriceOne := new(big.Int).Lsh(big.NewInt(1), 96)
	initializeData, err := managerABI.Pack("initialize", key, sqrtPriceOne)
	if err != nil {
		t.Fatalf("pack initialize: %v", err)
	}
	assertMethodSelector(t, initializeData, "initialize((address,address,uint24,int24,address),uint160)")

	_, liquidityABI, err := loadUniArtifact("PoolModifyLiquidityTest")
	if err != nil {
		t.Fatal(err)
	}
	liquidityData, err := packUniCall(liquidityABI, uniModifyLiquiditySig, key, uniModifyLiquidityParams{
		TickLower:      big.NewInt(uniPoolTickLower),
		TickUpper:      big.NewInt(uniPoolTickUpper),
		LiquidityDelta: new(big.Int).Set(uniLiquidityDelta),
	}, []byte{})
	if err != nil {
		t.Fatalf("pack modifyLiquidity: %v", err)
	}
	assertMethodSelector(t, liquidityData, "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)")

	_, swapABI, err := loadUniArtifact("PoolSwapTest")
	if err != nil {
		t.Fatal(err)
	}
	swapData, err := swapABI.Pack("swap", key, uniSwapParams{
		ZeroForOne:        false,
		AmountSpecified:   big.NewInt(-uniSwapAmount),
		SqrtPriceLimitX96: new(big.Int).Set(uniMaxSqrtPrice),
	}, uniTestSettings{}, []byte{})
	if err != nil {
		t.Fatalf("pack swap: %v", err)
	}
	assertMethodSelector(t, swapData, "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)")

	_, tokenABI, err := loadUniArtifact("AdventureToken")
	if err != nil {
		t.Fatal(err)
	}
	accountData, err := tokenABI.Pack("initializeAccounts", []ethcmn.Address{token}, router, uniTokenAmountPerAccount)
	if err != nil {
		t.Fatalf("pack initializeAccounts: %v", err)
	}
	assertMethodSelector(t, accountData, "initializeAccounts(address[],address,uint256)")
}

func TestUniPoolID(t *testing.T) {
	_, managerABI, err := loadUniArtifact("PoolManager")
	if err != nil {
		t.Fatal(err)
	}

	// This address/key pair is also covered by the local deployment receipt produced by
	// DeployAndSwap.s.sol, so the test detects tuple-layout regressions against an on-chain value.
	key := newUniPoolKey(ethcmn.HexToAddress("0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"))
	poolID, err := uniPoolID(managerABI, key)
	if err != nil {
		t.Fatal(err)
	}
	want := ethcmn.HexToHash("0x017ba77ad9921f21540f49c5d274a85e2d6051f3605408cc20f57cda153166ea")
	if poolID != want {
		t.Fatalf("pool id mismatch: got %s want %s", poolID.Hex(), want.Hex())
	}
}

func assertMethodSelector(t *testing.T, data []byte, signature string) {
	t.Helper()
	if len(data) < 4 {
		t.Fatalf("calldata for %s is too short", signature)
	}
	want := crypto.Keccak256([]byte(signature))[:4]
	if !bytes.Equal(data[:4], want) {
		t.Fatalf("selector mismatch for %s: got 0x%x want 0x%x", signature, data[:4], want)
	}
}
