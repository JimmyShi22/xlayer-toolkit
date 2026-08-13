package bench

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/okx/adventure/utils"
)

const (
	uniArtifactDir        = "artifacts/uniswap/"
	uniDeployGasLimit     = uint64(15_000_000)
	uniCallGasLimit       = uint64(1_000_000)
	uniSwapGasLimit       = uint64(300_000)
	uniAccountBatchSize   = 50
	uniPoolFee            = int64(3000)
	uniPoolTickSpacing    = int64(60)
	uniPoolTickLower      = int64(-600)
	uniPoolTickUpper      = int64(600)
	uniSwapAmount         = int64(1_000_000_000) // 1 gwei of ADV per swap.
	uniReceiptWaitPeriod  = 2 * time.Minute
	uniModifyLiquiditySig = "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)"
)

var (
	//go:embed artifacts/uniswap/*.json
	uniArtifactFiles embed.FS

	uniTokenAmountPerAccount = new(big.Int).Mul(big.NewInt(1_000_000), big.NewInt(1_000_000_000_000_000_000))
	uniLiquidityDelta        = new(big.Int).Mul(big.NewInt(10), big.NewInt(1_000_000_000_000_000_000))
	uniLiquidityValue        = big.NewInt(1_000_000_000_000_000_000)
	uniMaxSqrtPrice          = mustBigInt("1461446703485210103287273052203988822378723970341")
	uniMaxUint256            = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
)

type uniArtifact struct {
	ABI      json.RawMessage `json:"abi"`
	Bytecode string          `json:"bytecode"`
}

// Tuple structs intentionally follow the Solidity ABI names. Non-standard integer sizes such as
// uint24 and int24 are represented by *big.Int by go-ethereum's ABI package.
type uniPoolKey struct {
	Currency0   ethcmn.Address
	Currency1   ethcmn.Address
	Fee         *big.Int
	TickSpacing *big.Int
	Hooks       ethcmn.Address
}

type uniModifyLiquidityParams struct {
	TickLower      *big.Int
	TickUpper      *big.Int
	LiquidityDelta *big.Int
	Salt           [32]byte
}

type uniSwapParams struct {
	ZeroForOne        bool
	AmountSpecified   *big.Int
	SqrtPriceLimitX96 *big.Int
}

type uniTestSettings struct {
	TakeClaims      bool
	SettleUsingBurn bool
}

// UniInit deploys a Uniswap v4 PoolManager, the v4-core test settlement routers, a benchmark ERC20,
// and an ETH/ADV pool. It funds every selected benchmark account with native gas and provisions a
// large ADV balance plus an unlimited allowance to the swap router.
func UniInit(amountStr, configPath string) error {
	if err := loadConfig(configPath); err != nil {
		return err
	}
	if len(utils.TransferCfg.Rpc) == 0 {
		return errors.New("rpc must contain at least one endpoint")
	}
	if len(utils.TransferCfg.BenchmarkAccounts) == 0 {
		return errors.New("no benchmark accounts loaded")
	}
	if utils.TransferCfg.SenderPrivateKey == "" {
		return errors.New("senderPrivateKey must be set in config file")
	}

	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(utils.TransferCfg.SenderPrivateKey, "0x"))
	if err != nil {
		return fmt.Errorf("invalid senderPrivateKey")
	}
	deployer := utils.GetEthAddressFromPK(privateKey)
	accounts, err := uniBenchmarkAddresses(utils.TransferCfg.BenchmarkAccounts)
	if err != nil {
		return err
	}
	nativeAmount, err := parseAmountWithETH(amountStr)
	if err != nil {
		return err
	}

	cli := utils.NewClient(utils.TransferCfg.Rpc[0])

	// Match erc20-init: deploy the native batch distributor and provision gas first.
	nonce, err := cli.QueryNonce(deployer.Hex())
	if err != nil {
		return fmt.Errorf("query deployer nonce: %w", err)
	}
	nativeBatch, err := deployBTNative(cli, privateKey, nonce)
	if err != nil {
		return fmt.Errorf("deploy native batch transfer: %w", err)
	}
	if err := transfersNative(cli, privateKey, nonce+1, nativeBatch, nativeAmount, accounts); err != nil {
		return fmt.Errorf("fund benchmark accounts: %w", err)
	}

	manager, managerABI, err := deployUniArtifact(cli, privateKey, "PoolManager", deployer)
	if err != nil {
		return err
	}
	liquidityRouter, liquidityABI, err := deployUniArtifact(cli, privateKey, "PoolModifyLiquidityTest", manager)
	if err != nil {
		return err
	}
	swapRouter, _, err := deployUniArtifact(cli, privateKey, "PoolSwapTest", manager)
	if err != nil {
		return err
	}
	token, tokenABI, err := deployUniArtifact(cli, privateKey, "AdventureToken", deployer)
	if err != nil {
		return err
	}

	key := newUniPoolKey(token)
	if _, err := sendUniCall(cli, privateKey, token, tokenABI, "approve", uniCallGasLimit, nil, liquidityRouter, uniMaxUint256); err != nil {
		return fmt.Errorf("approve liquidity router: %w", err)
	}

	sqrtPriceOne := new(big.Int).Lsh(big.NewInt(1), 96)
	if _, err := sendUniCall(cli, privateKey, manager, managerABI, "initialize", uniCallGasLimit, nil, key, sqrtPriceOne); err != nil {
		return fmt.Errorf("initialize ETH/ADV pool: %w", err)
	}

	liquidityParams := uniModifyLiquidityParams{
		TickLower:      big.NewInt(uniPoolTickLower),
		TickUpper:      big.NewInt(uniPoolTickUpper),
		LiquidityDelta: new(big.Int).Set(uniLiquidityDelta),
	}
	if _, err := sendUniCall(
		cli, privateKey, liquidityRouter, liquidityABI, uniModifyLiquiditySig, 5_000_000,
		new(big.Int).Set(uniLiquidityValue), key, liquidityParams, []byte{},
	); err != nil {
		return fmt.Errorf("add ETH/ADV liquidity: %w", err)
	}

	// One owner transaction per account batch initializes both balance and allowance. This keeps
	// setup bounded while swaps still execute the normal ERC20 transferFrom settlement path.
	for start := 0; start < len(accounts); start += uniAccountBatchSize {
		end := start + uniAccountBatchSize
		if end > len(accounts) {
			end = len(accounts)
		}
		gasLimit := uint64(100_000*(end-start) + 200_000)
		hash, err := sendUniCall(
			cli, privateKey, token, tokenABI, "initializeAccounts", gasLimit, nil,
			accounts[start:end], swapRouter, uniTokenAmountPerAccount,
		)
		if err != nil {
			return fmt.Errorf("initialize accounts [%d,%d): %w", start, end, err)
		}
		log.Printf("[Uni account init] accounts[%d:%d] txhash=%s\n", start, end, hash.Hex())
	}

	poolID, err := uniPoolID(managerABI, key)
	if err != nil {
		return fmt.Errorf("compute pool id: %w", err)
	}
	log.Printf("✅ UNI_DEPLOYMENT PoolManager=%s LiquidityRouter=%s SwapRouter=%s ERC20=%s PoolId=%s\n",
		manager.Hex(), liquidityRouter.Hex(), swapRouter.Hex(), token.Hex(), poolID.Hex())
	log.Printf("✅ Initialized %d accounts with %s ADV each and unlimited SwapRouter allowance\n",
		len(accounts), uniTokenAmountPerAccount.String())
	return nil
}

// UniBench continuously submits exact-input ADV -> ETH swaps through the v4-core PoolSwapTest
// settlement router. TPS collection, account concurrency, batching, rate limiting and mempool
// backpressure are shared with the existing benchmarks through utils.RunTxs.
func UniBench(configPath, routerAddr, tokenAddr string) error {
	if configPath == "" {
		return errors.New("configPath must not be empty")
	}
	if !ethcmn.IsHexAddress(routerAddr) {
		return errors.New("router must be a valid address")
	}
	if !ethcmn.IsHexAddress(tokenAddr) {
		return errors.New("token must be a valid address")
	}
	if err := loadConfig(configPath); err != nil {
		return err
	}
	if len(utils.TransferCfg.BenchmarkAccounts) == 0 {
		return errors.New("no benchmark accounts loaded")
	}

	router := ethcmn.HexToAddress(routerAddr)
	token := ethcmn.HexToAddress(tokenAddr)
	_, routerABI, err := loadUniArtifact("PoolSwapTest")
	if err != nil {
		return err
	}

	key := newUniPoolKey(token)
	params := uniSwapParams{
		ZeroForOne:        false,
		AmountSpecified:   big.NewInt(-uniSwapAmount),
		SqrtPriceLimitX96: new(big.Int).Set(uniMaxSqrtPrice),
	}
	settings := uniTestSettings{TakeClaims: false, SettleUsingBurn: false}
	data, err := routerABI.Pack("swap", key, params, settings, []byte{})
	if err != nil {
		return fmt.Errorf("encode v4 swap: %w", err)
	}

	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	param := utils.NewTxParam(&router, nil, uniSwapGasLimit, gasPrice, data)
	log.Printf("uni-bench router=%s token=%s direction=ADV->ETH amountIn=%d fee=%d\n",
		router.Hex(), token.Hex(), uniSwapAmount, uniPoolFee)

	utils.RunTxs(func(_ ethcmn.Address) []utils.TxParam {
		return []utils.TxParam{param}
	})
	return nil
}

func newUniPoolKey(token ethcmn.Address) uniPoolKey {
	return uniPoolKey{
		Currency0:   ethcmn.Address{},
		Currency1:   token,
		Fee:         big.NewInt(uniPoolFee),
		TickSpacing: big.NewInt(uniPoolTickSpacing),
		Hooks:       ethcmn.Address{},
	}
}

func uniBenchmarkAddresses(entries []string) ([]ethcmn.Address, error) {
	addresses := make([]ethcmn.Address, len(entries))
	for i, entry := range entries {
		if ethcmn.IsHexAddress(entry) {
			addresses[i] = ethcmn.HexToAddress(entry)
			continue
		}
		key, err := crypto.HexToECDSA(strings.TrimPrefix(entry, "0x"))
		if err != nil {
			return nil, fmt.Errorf("benchmark account %d is neither an address nor a valid signing key", i)
		}
		addresses[i] = utils.GetEthAddressFromPK(key)
	}
	return addresses, nil
}

func loadUniArtifact(name string) (uniArtifact, abi.ABI, error) {
	data, err := uniArtifactFiles.ReadFile(uniArtifactDir + name + ".json")
	if err != nil {
		return uniArtifact{}, abi.ABI{}, fmt.Errorf("read embedded %s artifact: %w", name, err)
	}
	var artifact uniArtifact
	if err := json.Unmarshal(data, &artifact); err != nil {
		return uniArtifact{}, abi.ABI{}, fmt.Errorf("decode embedded %s artifact: %w", name, err)
	}
	parsed, err := abi.JSON(bytes.NewReader(artifact.ABI))
	if err != nil {
		return uniArtifact{}, abi.ABI{}, fmt.Errorf("parse embedded %s ABI: %w", name, err)
	}
	if artifact.Bytecode == "" {
		return uniArtifact{}, abi.ABI{}, fmt.Errorf("embedded %s artifact has no bytecode", name)
	}
	return artifact, parsed, nil
}

func deployUniArtifact(cli utils.Client, privateKey *ecdsa.PrivateKey, name string, constructorArgs ...interface{}) (ethcmn.Address, abi.ABI, error) {
	artifact, parsed, err := loadUniArtifact(name)
	if err != nil {
		return ethcmn.Address{}, abi.ABI{}, err
	}
	constructorData, err := parsed.Pack("", constructorArgs...)
	if err != nil {
		return ethcmn.Address{}, abi.ABI{}, fmt.Errorf("encode %s constructor: %w", name, err)
	}
	deploymentData := append(ethcmn.FromHex(artifact.Bytecode), constructorData...)
	deployer := utils.GetEthAddressFromPK(privateKey)
	nonce, err := cli.QueryNonce(deployer.Hex())
	if err != nil {
		return ethcmn.Address{}, abi.ABI{}, fmt.Errorf("query nonce for %s: %w", name, err)
	}
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	hash, err := cli.CreateContract(privateKey, nonce, nil, uniDeployGasLimit, gasPrice, deploymentData)
	if err != nil {
		return ethcmn.Address{}, abi.ABI{}, fmt.Errorf("deploy %s: %w", name, err)
	}
	address := crypto.CreateAddress(deployer, nonce)
	if _, err := waitForUniReceipt(cli, hash); err != nil {
		return ethcmn.Address{}, abi.ABI{}, fmt.Errorf("deploy %s: %w", name, err)
	}
	code, err := cli.CodeAt(context.Background(), address, nil)
	if err != nil || len(code) == 0 {
		return ethcmn.Address{}, abi.ABI{}, fmt.Errorf("deploy %s produced no code at %s", name, address.Hex())
	}
	log.Printf("%s: caller=%s nonce=%d contract=%s txhash=%s\n", name, deployer.Hex(), nonce, address.Hex(), hash.Hex())
	return address, parsed, nil
}

func sendUniCall(
	cli utils.Client,
	privateKey *ecdsa.PrivateKey,
	to ethcmn.Address,
	contractABI abi.ABI,
	method string,
	gasLimit uint64,
	value *big.Int,
	args ...interface{},
) (ethcmn.Hash, error) {
	data, err := packUniCall(contractABI, method, args...)
	if err != nil {
		return ethcmn.Hash{}, fmt.Errorf("encode %s: %w", method, err)
	}
	sender := utils.GetEthAddressFromPK(privateKey)
	nonce, err := cli.QueryNonce(sender.Hex())
	if err != nil {
		return ethcmn.Hash{}, fmt.Errorf("query nonce for %s: %w", method, err)
	}
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	hash, err := cli.SendEthereumTx(privateKey, nonce, to, value, gasLimit, gasPrice, data)
	if err != nil {
		return ethcmn.Hash{}, fmt.Errorf("send %s: %w", method, err)
	}
	if _, err := waitForUniReceipt(cli, hash); err != nil {
		return ethcmn.Hash{}, fmt.Errorf("confirm %s: %w", method, err)
	}
	return hash, nil
}

// packUniCall accepts either the ABI map name (e.g. "approve") or a canonical signature. Full
// signatures are needed for overloaded functions because go-ethereum assigns order-dependent map
// names such as modifyLiquidity0 to overloads.
func packUniCall(contractABI abi.ABI, nameOrSignature string, args ...interface{}) ([]byte, error) {
	if method, ok := contractABI.Methods[nameOrSignature]; ok {
		encoded, err := method.Inputs.Pack(args...)
		if err != nil {
			return nil, err
		}
		return append(method.ID, encoded...), nil
	}
	for _, method := range contractABI.Methods {
		if method.Sig == nameOrSignature {
			encoded, err := method.Inputs.Pack(args...)
			if err != nil {
				return nil, err
			}
			return append(method.ID, encoded...), nil
		}
	}
	return nil, fmt.Errorf("method %q not found in ABI", nameOrSignature)
}

func waitForUniReceipt(cli utils.Client, hash ethcmn.Hash) (*types.Receipt, error) {
	ethClient, ok := cli.(*utils.EthClient)
	if !ok {
		return nil, errors.New("receipt waiting requires an Ethereum client")
	}
	ctx, cancel := context.WithTimeout(context.Background(), uniReceiptWaitPeriod)
	defer cancel()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		receipt, err := ethClient.TransactionReceipt(ctx, hash)
		if err == nil {
			if receipt.Status != types.ReceiptStatusSuccessful {
				return nil, fmt.Errorf("transaction %s reverted", hash.Hex())
			}
			return receipt, nil
		}
		if !errors.Is(err, ethereum.NotFound) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("timed out waiting for transaction %s", hash.Hex())
		case <-ticker.C:
		}
	}
}

func uniPoolID(managerABI abi.ABI, key uniPoolKey) (ethcmn.Hash, error) {
	initialize, ok := managerABI.Methods["initialize"]
	if !ok || len(initialize.Inputs) == 0 {
		return ethcmn.Hash{}, errors.New("PoolManager ABI has no initialize input")
	}
	encoded, err := initialize.Inputs[:1].Pack(key)
	if err != nil {
		return ethcmn.Hash{}, err
	}
	return crypto.Keccak256Hash(encoded), nil
}

func mustBigInt(value string) *big.Int {
	result, ok := new(big.Int).SetString(value, 10)
	if !ok {
		panic("invalid integer constant")
	}
	return result
}
