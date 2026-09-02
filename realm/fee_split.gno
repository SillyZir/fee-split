package fee_split

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"sort"
	"strconv"
	"strings"
)

// Split holds a fee-splitting configuration with percentage-based shares
// denominated in basis points (1 bp = 0.01%, 10000 bp = 100%).
type Split struct {
	Owner          address
	Recipients     []address
	Shares         []int64 // basis points, must sum to 10000
	Balances       map[address]int64
	TotalDeposited int64
	TotalClaimed   int64
	Frozen         bool
	Archived       bool
}

const (
	MaxRecipients     = 20
	MaxSplitsPerOwner = 10
	MaxSplitsGlobal   = 500

	// Denomination handled by this realm. Deposits must be exactly one
	// coin of this denom; claims pay out in it.
	Denom = "ugnot"

	// Largest single deposit for which share math (amount * share,
	// share <= 10000) cannot overflow int64.
	MaxDepositAmount = int64(9223372036854775807) / 10000
)

var (
	splits      map[string]*Split
	splitIDs    []string // insertion-ordered for deterministic Render
	ownerSplits map[address]int
	nextID      int
)

func init() {
	splits = make(map[string]*Split)
	splitIDs = []string{}
	ownerSplits = make(map[address]int)
	nextID = 1
}

func caller() address {
	return runtime.PreviousRealm().Address()
}

// ---------- helpers ----------

func formatPct(bp int64) string {
	whole := strconv.FormatInt(bp/100, 10)
	frac := strconv.FormatInt(bp%100, 10)
	if len(frac) == 1 {
		frac = "0" + frac
	}
	return whole + "." + frac + "%"
}

func mustGetSplit(id string) *Split {
	s, ok := splits[id]
	if !ok {
		panic("split not found: " + id)
	}
	return s
}

func mustGetActive(id string) *Split {
	s := mustGetSplit(id)
	if s.Archived {
		panic("split is archived: " + id)
	}
	return s
}

func boolStr(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

func parseBasisPoints(raw string) []int64 {
	parts := strings.Split(raw, ",")
	out := make([]int64, len(parts))
	var total int64
	for i, s := range parts {
		v, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || v <= 0 {
			panic("invalid share value: " + strings.TrimSpace(s))
		}
		out[i] = int64(v)
		total += int64(v)
	}
	if total != 10000 {
		panic("shares must sum to 10000 basis points, got " + strconv.FormatInt(total, 10))
	}
	return out
}

func parseAddresses(raw string) []address {
	parts := strings.Split(raw, ",")
	out := make([]address, len(parts))
	for i, r := range parts {
		a := address(strings.TrimSpace(r))
		if a == "" {
			panic("empty recipient address at position " + strconv.Itoa(i))
		}
		if !a.IsValid() {
			panic("invalid recipient address: " + string(a))
		}
		out[i] = a
	}
	return out
}

func validateRecipients(recipients []address, shares []int64) {
	if len(recipients) != len(shares) {
		panic("recipients and shares must have the same length")
	}
	if len(recipients) == 0 {
		panic("at least one recipient is required")
	}
	if len(recipients) > MaxRecipients {
		panic("too many recipients (max " + strconv.Itoa(MaxRecipients) + ")")
	}
	seen := make(map[address]bool)
	for _, r := range recipients {
		if seen[r] {
			panic("duplicate recipient: " + string(r))
		}
		seen[r] = true
	}
}

// sortedBalanceAddrs returns the balance-map keys in deterministic order,
// so panics and renders never depend on map iteration order.
func sortedBalanceAddrs(s *Split) []string {
	addrs := make([]string, 0, len(s.Balances))
	for a := range s.Balances {
		addrs = append(addrs, string(a))
	}
	sort.Strings(addrs)
	return addrs
}

// ---------- write operations ----------

// CreateSplit registers a new split. The caller becomes the owner.
// Recipients and shares are comma-separated; shares are in basis points
// summing to 10000.
func CreateSplit(_ realm, recipientList, shareList string) string {
	if len(splits) >= MaxSplitsGlobal {
		panic("global split limit reached")
	}
	owner := caller()
	if ownerSplits[owner] >= MaxSplitsPerOwner {
		panic("per-owner split limit reached")
	}

	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)
	validateRecipients(recipients, shares)

	id := "split_" + strconv.Itoa(nextID)
	nextID++

	balances := make(map[address]int64)
	for _, r := range recipients {
		balances[r] = 0
	}

	splits[id] = &Split{
		Owner:      owner,
		Recipients: recipients,
		Shares:     shares,
		Balances:   balances,
	}
	splitIDs = append(splitIDs, id)
	ownerSplits[owner]++
	return id
}

// Deposit distributes the coins sent with the call across recipients
// proportionally. The deposit is the ACTUAL attached send — exactly one
// coin of Denom — so balances are always backed by funds this realm
// holds. Direct user calls only: a deposit routed through an
// intermediary realm would deliver its coins to that realm, not here,
// and must be rejected. Rounding dust goes to the highest-share
// recipient (deterministic, not order-dependent).
func Deposit(_ realm, splitID string) {
	s := mustGetActive(splitID)
	if s.Frozen {
		panic("split is frozen")
	}

	if !runtime.PreviousRealm().IsUser() {
		panic("deposits must be sent directly, not through another realm")
	}
	sent := banker.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("deposit must send exactly one coin of " + Denom)
	}
	amount := sent[0].Amount
	if amount <= 0 {
		panic("amount must be greater than zero")
	}
	if amount > MaxDepositAmount {
		panic("deposit exceeds maximum supported amount")
	}
	if s.TotalDeposited > int64(9223372036854775807)-amount {
		panic("deposit would overflow split accounting")
	}

	s.TotalDeposited += amount

	// Find the highest-share recipient for dust assignment
	dustIdx := 0
	for i := 1; i < len(s.Shares); i++ {
		if s.Shares[i] > s.Shares[dustIdx] {
			dustIdx = i
		}
	}

	var distributed int64
	for i, r := range s.Recipients {
		share := (amount * s.Shares[i]) / 10000
		s.Balances[r] += share
		distributed += share
	}

	// Assign dust to highest-share recipient
	dust := amount - distributed
	if dust > 0 {
		s.Balances[s.Recipients[dustIdx]] += dust
	}
}

// Claim withdraws the caller's accumulated balance and SENDS the coins
// to the caller's address. Balance is zeroed before the transfer.
// Claims remain possible on frozen splits, and by ex-recipients whose
// accrued balance predates a share update.
func Claim(_ realm, splitID string) int64 {
	s := mustGetActive(splitID)
	addr := caller()

	bal, exists := s.Balances[addr]
	if !exists {
		panic("not a recipient of this split")
	}
	if bal == 0 {
		panic("nothing to claim")
	}

	s.Balances[addr] = 0
	s.TotalClaimed += bal

	b := banker.NewBanker(banker.BankerTypeRealmSend)
	b.SendCoins(runtime.CurrentRealm().Address(), addr,
		chain.Coins{{Denom: Denom, Amount: bal}})
	return bal
}

// UpdateShares replaces recipients and shares. Owner only. Not if frozen.
// Removed recipients keep any accrued balance and can still Claim it.
func UpdateShares(_ realm, splitID, recipientList, shareList string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can update shares")
	}
	if s.Frozen {
		panic("split is frozen")
	}

	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)
	validateRecipients(recipients, shares)

	for _, r := range recipients {
		if _, ok := s.Balances[r]; !ok {
			s.Balances[r] = 0
		}
	}

	s.Recipients = recipients
	s.Shares = shares
}

// TransferOwnership hands control to a new owner. The per-owner split
// slot moves with it: the old owner's count is freed and the new
// owner's is consumed (and must be under the limit).
func TransferOwnership(_ realm, splitID string, newOwner address) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		panic("new owner must not be empty")
	}
	if !newOwner.IsValid() {
		panic("invalid new owner address: " + string(newOwner))
	}
	if newOwner == s.Owner {
		panic("new owner is already the owner")
	}
	if ownerSplits[newOwner] >= MaxSplitsPerOwner {
		panic("new owner is at the per-owner split limit")
	}

	ownerSplits[s.Owner]--
	if ownerSplits[s.Owner] <= 0 {
		delete(ownerSplits, s.Owner)
	}
	ownerSplits[newOwner]++
	s.Owner = newOwner
}

// Freeze permanently locks shares and stops further deposits. One-way,
// cannot be undone. Claims remain possible.
func Freeze(_ realm, splitID string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can freeze")
	}
	s.Frozen = true
}

// Archive marks a fully-claimed split as archived. Only the owner can
// archive, and only if EVERY balance — including balances held by
// ex-recipients removed in a share update — is zero, since archiving
// blocks all further claims. Cannot be undone.
func Archive(_ realm, splitID string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can archive")
	}

	for _, a := range sortedBalanceAddrs(s) {
		if s.Balances[address(a)] > 0 {
			panic("cannot archive: outstanding balance for " + a)
		}
	}

	s.Archived = true

	// Free the owner's slot so they can create new splits
	ownerSplits[s.Owner]--
	if ownerSplits[s.Owner] <= 0 {
		delete(ownerSplits, s.Owner)
	}

	// Remove from active ID list (keeps map entry for audit)
	for i, id := range splitIDs {
		if id == splitID {
			splitIDs = append(splitIDs[:i], splitIDs[i+1:]...)
			break
		}
	}
}

// ---------- read-only queries ----------

// GetSplitInfo returns a human-readable summary.
func GetSplitInfo(splitID string) string {
	s := mustGetSplit(splitID)

	var b strings.Builder
	b.WriteString("Split: " + splitID + "\n")
	b.WriteString("Owner: " + string(s.Owner) + "\n")
	b.WriteString("Frozen: " + boolStr(s.Frozen) + "\n")
	b.WriteString("Total deposited: " + strconv.FormatInt(s.TotalDeposited, 10) + "\n")
	b.WriteString("Total claimed: " + strconv.FormatInt(s.TotalClaimed, 10) + "\n")
	b.WriteString("Recipients:\n")
	for i, r := range s.Recipients {
		b.WriteString("  " + string(r) + "  " + formatPct(s.Shares[i]) + "  claimable: " + strconv.FormatInt(s.Balances[r], 10) + "\n")
	}
	return b.String()
}

// GetClaimable returns claimable balance for an address.
func GetClaimable(splitID string, addr address) int64 {
	s := mustGetSplit(splitID)
	return s.Balances[addr]
}

// ---------- render ----------

// Render returns a markdown overview. Never panics.
func Render(path string) string {
	if splits == nil || len(splits) == 0 {
		return "# Fee Split\n\nNo active splits.\n"
	}

	var b strings.Builder
	b.WriteString("# Fee Split\n\n")

	for _, id := range splitIDs {
		s := splits[id]
		b.WriteString("## " + id + "\n\n")
		if s == nil {
			b.WriteString("_(invalid)_\n\n")
			continue
		}
		b.WriteString("```\n")
		b.WriteString("Owner: " + string(s.Owner) + "\n")
		b.WriteString("Frozen: " + boolStr(s.Frozen) + "\n")
		b.WriteString("Total deposited: " + strconv.FormatInt(s.TotalDeposited, 10) + "\n")
		b.WriteString("Total claimed: " + strconv.FormatInt(s.TotalClaimed, 10) + "\n")
		if len(s.Recipients) > 0 {
			b.WriteString("Recipients:\n")
			for i, r := range s.Recipients {
				share := "??%"
				if i < len(s.Shares) {
					share = formatPct(s.Shares[i])
				}
				bal := "0"
				if s.Balances != nil {
					bal = strconv.FormatInt(s.Balances[r], 10)
				}
				b.WriteString("  " + string(r) + "  " + share + "  claimable: " + bal + "\n")
			}
		}
		b.WriteString("```\n\n")
	}
	return b.String()
}
