package fee_split

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner    = testutils.TestAddress("owner")
	alice    = testutils.TestAddress("alice")
	bob      = testutils.TestAddress("bob")
	carol    = testutils.TestAddress("carol")
	dave     = testutils.TestAddress("dave")
	attacker = testutils.TestAddress("attacker")
)

// resetState resets all package-level state between tests.
// Required because Gno test functions share the same VM context.
func resetState() {
	splits = make(map[string]*Split)
	splitIDs = []string{}
	ownerSplits = make(map[address]int)
	nextID = 1
}

func addrList(addrs ...address) string {
	parts := make([]string, len(addrs))
	for i, a := range addrs {
		parts[i] = string(a)
	}
	return strings.Join(parts, ",")
}

// fund gives the realm's package address coins so Claim payouts succeed,
// mirroring the deposits the accounting records.
func fund(amount int64) {
	pkgAddr := chain.PackageAddress("gno.land/r/fee_split")
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: Denom, Amount: amount}})
}

// deposit performs a coin-backed deposit as addr.
func deposit(addr address, splitID string, amount int64) {
	testing.SetRealm(testing.NewUserRealm(addr))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: amount}})
	fund(amount)
	Deposit(cross, splitID)
	testing.SetOriginSend(nil)
}

// ---------- CreateSplit ----------

func TestCreateSplit_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	id := CreateSplit(cross, addrList(alice, bob), "6000,4000")
	uassert.Equal(t, "split_1", id)

	s := splits["split_1"]
	uassert.Equal(t, string(owner), string(s.Owner))
	uassert.Equal(t, 2, len(s.Recipients))
	uassert.Equal(t, string(alice), string(s.Recipients[0]))
	uassert.Equal(t, string(bob), string(s.Recipients[1]))
	uassert.Equal(t, int64(6000), s.Shares[0])
	uassert.Equal(t, int64(4000), s.Shares[1])
	uassert.False(t, s.Frozen, "new split must not be frozen")
	uassert.Equal(t, int64(0), s.TotalDeposited)
	uassert.Equal(t, int64(0), s.TotalClaimed)
}

func TestCreateSplit_IDsIncrement(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	id1 := CreateSplit(cross, addrList(alice), "10000")
	id2 := CreateSplit(cross, addrList(bob), "10000")
	uassert.Equal(t, "split_1", id1)
	uassert.Equal(t, "split_2", id2)
}

func TestCreateSplit_DuplicateRecipient(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t,
		"duplicate recipient: "+string(alice),
		func() { CreateSplit(cross, addrList(alice, alice), "5000,5000") },
	)
}

func TestCreateSplit_SharesDontSum(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t,
		"shares must sum to 10000 basis points, got 5000",
		func() { CreateSplit(cross, addrList(alice), "5000") },
	)
}

func TestCreateSplit_LengthMismatch(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t,
		"recipients and shares must have the same length",
		func() { CreateSplit(cross, addrList(alice, bob), "10000") },
	)
}

func TestCreateSplit_InvalidAddressRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t,
		"invalid recipient address: not_an_address",
		func() { CreateSplit(cross, "not_an_address", "10000") },
	)
}

func TestCreateSplit_PerOwnerLimit(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross, addrList(alice), "10000")
	}
	uassert.AbortsWithMessage(t,
		"per-owner split limit reached",
		func() { CreateSplit(cross, addrList(alice), "10000") },
	)
}

// ---------- Deposit (coin-backed) ----------

func TestDeposit_UsesSentCoins(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")

	deposit(owner, id, 1000)

	s := splits[id]
	uassert.Equal(t, int64(1000), s.TotalDeposited)
	uassert.Equal(t, int64(500), s.Balances[alice])
	uassert.Equal(t, int64(500), s.Balances[bob])
}

func TestDeposit_NoCoinsPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	// no SetOriginSend: nothing attached to the call
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t,
		"deposit must send exactly one coin of "+Denom,
		func() { Deposit(cross, id) },
	)
	uassert.Equal(t, int64(0), splits[id].TotalDeposited)
}

func TestDeposit_WrongDenomPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	testing.SetOriginSend(chain.Coins{{Denom: "ufoo", Amount: 100}})
	uassert.AbortsWithMessage(t,
		"deposit must send exactly one coin of "+Denom,
		func() { Deposit(cross, id) },
	)
	testing.SetOriginSend(nil)
}

func TestDeposit_RoundingDustGoesToHighestShare(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob, carol), "3334,3333,3333")

	deposit(owner, id, 10)

	s := splits[id]
	uassert.Equal(t, int64(10), s.TotalDeposited)
	// alice: (10*3334)/10000 = 3, +1 dust (highest share)
	uassert.Equal(t, int64(4), s.Balances[alice])
	uassert.Equal(t, int64(3), s.Balances[bob])
	uassert.Equal(t, int64(3), s.Balances[carol])
}

func TestDeposit_AccumulatesAcrossMultipleDeposits(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")

	deposit(owner, id, 100)
	deposit(owner, id, 200)

	s := splits[id]
	uassert.Equal(t, int64(300), s.TotalDeposited)
	uassert.Equal(t, int64(150), s.Balances[alice])
	uassert.Equal(t, int64(150), s.Balances[bob])
}

func TestDeposit_OverflowGuard(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: MaxDepositAmount + 1}})
	uassert.AbortsWithMessage(t,
		"deposit exceeds maximum supported amount",
		func() { Deposit(cross, id) },
	)
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(0), splits[id].TotalDeposited)
}

func TestDeposit_FrozenSplitPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	Freeze(cross, id)

	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 100}})
	uassert.AbortsWithMessage(t,
		"split is frozen",
		func() { Deposit(cross, id) },
	)
	testing.SetOriginSend(nil)
}

func TestDeposit_UnknownSplitPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t,
		"split not found: split_99",
		func() { Deposit(cross, "split_99") },
	)
}

// ---------- Claim (pays out coins) ----------

func TestClaim_SendsCoins(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "7000,3000")
	deposit(owner, id, 10000)

	before := banker.NewBanker(banker.BankerTypeReadonly).GetCoins(alice).AmountOf(Denom)

	testing.SetRealm(testing.NewUserRealm(alice))
	claimed := Claim(cross, id)
	uassert.Equal(t, int64(7000), claimed)

	after := banker.NewBanker(banker.BankerTypeReadonly).GetCoins(alice).AmountOf(Denom)
	uassert.Equal(t, int64(7000), after-before)

	s := splits[id]
	uassert.Equal(t, int64(0), s.Balances[alice])
	uassert.Equal(t, int64(7000), s.TotalClaimed)
}

func TestClaim_CallerIdentityIsEnforced(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	deposit(owner, id, 100)

	// the attacker cannot claim alice's balance: identity comes from the
	// chain, not from an argument
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"not a recipient of this split",
		func() { Claim(cross, id) },
	)
	uassert.Equal(t, int64(100), splits[id].Balances[alice])
}

func TestClaim_NothingToClaim(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t,
		"nothing to claim",
		func() { Claim(cross, id) },
	)
}

func TestClaim_CannotClaimTwice(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	deposit(owner, id, 100)

	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross, id)
	uassert.AbortsWithMessage(t,
		"nothing to claim",
		func() { Claim(cross, id) },
	)
}

func TestClaim_ExRecipientKeepsAccruedBalance(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")
	deposit(owner, id, 1000)

	testing.SetRealm(testing.NewUserRealm(owner))
	UpdateShares(cross, id, addrList(carol, dave), "6000,4000")

	// bob was removed but keeps — and can claim — his accrued 500
	testing.SetRealm(testing.NewUserRealm(bob))
	claimed := Claim(cross, id)
	uassert.Equal(t, int64(500), claimed)
}

// ---------- UpdateShares ----------

func TestUpdateShares_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")

	UpdateShares(cross, id, addrList(alice, carol), "7000,3000")

	s := splits[id]
	uassert.Equal(t, 2, len(s.Recipients))
	uassert.Equal(t, string(alice), string(s.Recipients[0]))
	uassert.Equal(t, string(carol), string(s.Recipients[1]))
	uassert.Equal(t, int64(7000), s.Shares[0])
	uassert.Equal(t, int64(3000), s.Shares[1])
}

func TestUpdateShares_PreservesUnclaimedBalances(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")
	deposit(owner, id, 1000)

	testing.SetRealm(testing.NewUserRealm(owner))
	UpdateShares(cross, id, addrList(carol, dave), "6000,4000")

	s := splits[id]
	uassert.Equal(t, int64(500), s.Balances[alice])
	uassert.Equal(t, int64(500), s.Balances[bob])
}

func TestUpdateShares_WrongOwner(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"only the owner can update shares",
		func() { UpdateShares(cross, id, addrList(alice), "10000") },
	)
}

func TestUpdateShares_FrozenSplitPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	Freeze(cross, id)

	uassert.AbortsWithMessage(t,
		"split is frozen",
		func() { UpdateShares(cross, id, addrList(alice, bob), "5000,5000") },
	)
}

// ---------- TransferOwnership ----------

func TestTransferOwnership_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	TransferOwnership(cross, id, bob)
	uassert.Equal(t, string(bob), string(splits[id].Owner))
}

func TestTransferOwnership_WrongOwner(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"only the owner can transfer ownership",
		func() { TransferOwnership(cross, id, attacker) },
	)
}

func TestTransferOwnership_MovesOwnerSlot(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	uassert.Equal(t, 1, ownerSplits[owner])

	TransferOwnership(cross, id, bob)

	// the creator's slot is freed; the new owner's is consumed
	uassert.Equal(t, 0, ownerSplits[owner])
	uassert.Equal(t, 1, ownerSplits[bob])

	// and the creator can fill the freed slot again
	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross, addrList(alice), "10000")
	}
}

func TestTransferOwnership_NewOwnerAtLimitBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(bob))
	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross, addrList(alice), "10000")
	}

	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	uassert.AbortsWithMessage(t,
		"new owner is at the per-owner split limit",
		func() { TransferOwnership(cross, id, bob) },
	)
}

// ---------- Freeze ----------

func TestFreeze_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	Freeze(cross, id)
	uassert.True(t, splits[id].Frozen, "split must be frozen after Freeze()")
}

func TestFreeze_WrongOwner(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"only the owner can freeze",
		func() { Freeze(cross, id) },
	)
}

func TestFreeze_ClaimsStillWork(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	deposit(owner, id, 100)

	testing.SetRealm(testing.NewUserRealm(owner))
	Freeze(cross, id)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(100), Claim(cross, id))
}

// ---------- Archive ----------

func TestArchive_BlocksWithOutstandingBalance(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice), "10000")
	deposit(owner, id, 100)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t,
		"cannot archive: outstanding balance for "+string(alice),
		func() { Archive(cross, id) },
	)
}

func TestArchive_BlocksOnExRecipientBalance(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")
	deposit(owner, id, 1000)

	testing.SetRealm(testing.NewUserRealm(owner))
	// remove bob; his 500 stays claimable
	UpdateShares(cross, id, addrList(alice), "10000")
	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross, id)

	// archive must refuse while the EX-recipient still has a balance —
	// archiving would lock his claim forever
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t,
		"cannot archive: outstanding balance for "+string(bob),
		func() { Archive(cross, id) },
	)

	// once bob claims, archive succeeds
	testing.SetRealm(testing.NewUserRealm(bob))
	Claim(cross, id)
	testing.SetRealm(testing.NewUserRealm(owner))
	Archive(cross, id)
	uassert.True(t, splits[id].Archived, "split must be archived")
}

// ---------- queries ----------

func TestGetClaimable(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "8000,2000")
	deposit(owner, id, 5000)

	uassert.Equal(t, int64(4000), GetClaimable(id, alice))
	uassert.Equal(t, int64(1000), GetClaimable(id, bob))
	uassert.Equal(t, int64(0), GetClaimable(id, attacker))
}

func TestGetSplitInfo_ContainsExpectedFields(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross, addrList(alice, bob), "5000,5000")
	deposit(owner, id, 200)

	info := GetSplitInfo(id)
	uassert.True(t, strings.Contains(info, "Owner"), "GetSplitInfo output must contain 'Owner'")
	uassert.True(t, strings.Contains(info, string(owner)), "GetSplitInfo output must contain owner address")
	uassert.True(t, strings.Contains(info, string(alice)), "GetSplitInfo output must contain recipient")
}

// ---------- render ----------

func TestRender_EmptyState(cur realm, t *testing.T) {
	resetState()

	out := Render("")
	uassert.Equal(t, "# Fee Split\n\nNo active splits.\n", out)
}

func TestRender_WithSplits(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	CreateSplit(cross, addrList(alice, bob), "6000,4000")
	deposit(owner, "split_1", 1000)

	out := Render("")
	uassert.True(t, strings.Contains(out, "split_1"), "Render output must reference split_1")
	uassert.True(t, strings.Contains(out, string(owner)), "Render output must include owner")
}
