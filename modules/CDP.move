address 0x1 {

/// Auction is a contract for selling assets in the given
/// interval of time (or possible implementation - when top bid is reached)
/// Scheme is super easy:
/// 1. owner places an asset for starting price in another asset.
/// Currently the only possible asset type is Dfinance::T - a registered coin.
/// 2. bidders place their bids which are stored inside Auction::T resource
/// highest bidder wins when auction is closed by its owner
/// 3. owner takes the bid and bidder gets the asset
///
/// Optional TODOs:
/// - set optional minimal step size (say, 10000 units)
/// - add error codes for operations in this contract
/// - add end strategy - by time or by reaching the max value
module Auction {

    use 0x1::Dfinance;
    use 0x1::Account;
    use 0x1::Signer;
    use 0x1::Event;

    /// Resource of the Auction. Stores max_bid and the bidder
    /// address for sending asset back or rewarding the winner.
    resource struct T<Lot, For> {
        lot: Dfinance::T<Lot>,
        max_bid: Dfinance::T<For>,
        start_price: u128,
        bidder: address,
        ends_at: u64
    }

    struct AuctionCreatedEvent<Lot, For> {
        owner: address,
        ends_at: u64,
        lot_amount: u128,
        start_price: u128,
    }

    struct BidPlacedEvent<Lot, For> {
        owner: address,
        bidder: address,
        bid_amount: u128
    }

    struct AuctionEndEvent<Lot, For> {
        owner: address,
        bidder: address,
        bid_amount: u128
    }

    /// Create Auction resource under Owner (sender) address
    /// Set default bidder as owner, max bid to 0 and start_price
    public fun create<Lot: copyable, For: copyable>(
        account: &signer,
        start_price: u128,
        lot: Dfinance::T<Lot>,
        ends_at: u64
    ) {
        let owner = Signer::address_of(account);
        let lot_amount = Dfinance::value(&lot);

        move_to<T<Lot, For>>(account, T {
            lot,
            ends_at,
            start_price,
            max_bid: Dfinance::zero<For>(),
            bidder: owner
        });

        Event::emit<AuctionCreatedEvent<Lot, For>>(
            account,
            AuctionCreatedEvent {
                owner,
                ends_at,
                lot_amount,
                start_price,
            }
        );
    }

    /// Check whether someone has published an auction for specific ticker
    public fun has_auction<Lot, For>(owner: address): bool {
        exists<T<Lot, For>>(owner)
    }

    /// Get offered amount and max bid at the time
    public fun get_details<Lot, For>(
        owner: address
    ): (u128, u128, u128) acquires T {
        let auction = borrow_global<T<Lot, For>>(owner);

        (
            auction.start_price,
            Dfinance::value(&auction.lot),
            Dfinance::value(&auction.max_bid)
        )
    }

    /// Place a bid for specific auction at address.
    /// What's a bit complicated is sending previous bid to its owner.
    /// But looks like there is a solution at the moment.
    public fun place_bid<Lot: copyable, For: copyable>(
        account: &signer,
        auction_owner: address,
        bid: Dfinance::T<For>
    ) acquires T {

        let bidder  = Signer::address_of(account);
        let auction = borrow_global_mut<T<Lot, For>>(auction_owner);
        let bid_amt = Dfinance::value(&bid);
        let max_bid = Dfinance::value(&auction.max_bid);

        assert(bid_amt > max_bid, 1);
        assert(bidder != auction.bidder, 1);
        assert(bid_amt >= auction.start_price, 1);

        // in case it's not empty bid by lender
        if (max_bid > 0) {
            let to_send_back = Dfinance::withdraw(&mut auction.max_bid, max_bid);
            Account::deposit<For>(account, auction.bidder, to_send_back);
        };

        // zero is left, filling with new bid
        Dfinance::deposit(&mut auction.max_bid, bid);

        // and changing the owner of current bid
        auction.bidder = bidder;

        Event::emit<BidPlacedEvent<Lot, For>>(
            account,
            BidPlacedEvent {
                bidder,
                owner: auction_owner,
                bid_amount: bid_amt
            }
        );
    }

    /// End auction: destroy resource, give lot to bidder and bid to owner
    public fun end_auction<Lot: copyable, For: copyable>(
        account: &signer
    ) acquires T {

        let owner = Signer::address_of(account);

        let T {
            lot,
            bidder,
            max_bid,
            ends_at: _,
            start_price: _,
        } = move_from<T<Lot, For>>(owner);

        let bid_amount = Dfinance::value(&max_bid);

        Account::deposit_to_sender(account, max_bid);
        Account::deposit(account, bidder, lot);

        Event::emit<AuctionEndEvent<Lot, For>>(
            account,
            AuctionEndEvent {
                owner,
                bidder,
                bid_amount
            }
        );
    }
}

module CDP {

    use 0x1::Oracle;
    use 0x1::Auction;
    use 0x1::Dfinance;
    use 0x1::Account;
    use 0x1::Signer;
    use 0x1::Event;

    const ORACLE_DECIMALS : u8 = 8;

    const ERR_DEAL_IS_OKAY : u64 = 200;
    const ERR_NO_RATE : u64 = 401;
    const ERR_NOT_LENDER : u64 = 402;
    const ERR_INCORRECT_ARGUMENT : u64 = 400;

    const DEAL_NOT_MADE : u8 = 0;
    const DEAL_OKAY : u8 = 1;
    const DEAL_PAST_MARGIN_CALL : u8 = 2;

    /// CDP resource
    resource struct T<Offered, Collateral> {
        offered_amount: u128,
        collateral: Dfinance::T<Collateral>,
        margin_call_rate: u64,
        current_rate: u64,
        lender: address
    }

    struct OfferTakenEvent<Offered, Collateral> {
        offered_amount: u128,
        collateral_amount: u128,
        margin_call_rate: u64,
        current_rate: u64,
        borrower: address,
        lender: address
    }

    struct OfferCreatedEvent<Offered, Collateral> {
        offered_amount: u128,
        margin_call_at: u8,
        collateral_multiplier: u8,
        lender: address
    }

    struct OfferCancelledEvent<Offered, Collateral> {
        lender: address
    }

    struct OfferClosedEvent<Offered, Collateral> {
        borrower: address,
        lender: address,
        current_rate: u64,
        offered_amount: u128,
        margin_call_rate: u64,
        initiative: address
    }

    public fun finish_and_create_auction<
        Offered: copyable,
        Collateral: copyable
    >(
        account: &signer,
        borrower: address
    ) acquires T {

        let deal_status = check_deal<Offered, Collateral>(borrower);

        assert(deal_status == DEAL_PAST_MARGIN_CALL, ERR_DEAL_IS_OKAY);

        let T {
            lender,
            collateral,
            offered_amount,
            current_rate: _,
            margin_call_rate,
        } = move_from<T<Offered, Collateral>>(borrower);

        assert(Signer::address_of(account) == lender, ERR_NOT_LENDER);

        Auction::create<Collateral, Offered>(
            account,
            offered_amount,
            collateral,
            0 // TODO
        );

        let current_rate = Oracle::get_price<Offered, Collateral>();

        Event::emit<OfferClosedEvent<Offered, Collateral>>(
            account,
            OfferClosedEvent {
                lender,
                borrower,
                current_rate,
                offered_amount,
                margin_call_rate,
                initiative: lender
            }
        );
    }

    public fun finish_and_release_funds<
        Offered: copyable,
        Collateral: copyable
    >(
        account: &signer,
        borrower: address
    ) acquires T {

        let deal_status = check_deal<Offered, Collateral>(borrower);

        assert(deal_status == DEAL_PAST_MARGIN_CALL, ERR_DEAL_IS_OKAY);

        let T {
            lender,
            collateral,
            offered_amount,
            current_rate: _,
            margin_call_rate,
        } = move_from<T<Offered, Collateral>>(borrower);

        assert(Signer::address_of(account) == lender, ERR_NOT_LENDER);

        Account::deposit_to_sender<Collateral>(account, collateral);

        let current_rate = Oracle::get_price<Offered, Collateral>();

        Event::emit<OfferClosedEvent<Offered, Collateral>>(
            account,
            OfferClosedEvent {
                lender,
                borrower,
                current_rate,
                offered_amount,
                margin_call_rate,
                initiative: lender
            }
        );
    }

    public fun return_money<
        Offered: copyable,
        Collateral: copyable
    >(
        account: &signer
    ) acquires T {
        let borrower = Signer::address_of(account);
        let deal_status = check_deal<Offered, Collateral>(borrower);

        assert(deal_status == DEAL_OKAY, 0); // TODO: ERROR CODE HERE

        let T {
            lender,
            collateral,
            current_rate,
            offered_amount,
            margin_call_rate,
        } = move_from<T<Offered, Collateral>>(borrower);

        let borrower_balance = Account::balance<Offered>(account);

        assert(borrower_balance >= offered_amount, 0); // TODO: ERROR STATUS HERE!!!!

        Account::deposit_to_sender<Collateral>(account, collateral);
        Account::pay_from_sender<Offered>(account, lender, offered_amount);

        // Deal is done. Resource no longer exists,

        Event::emit<OfferClosedEvent<Offered, Collateral>>(
            account,
            OfferClosedEvent {
                lender,
                borrower,
                current_rate,
                offered_amount,
                margin_call_rate,
                initiative: borrower
            }
        );
    }

    public fun get_deal_details<Offered, Collateral>(
        borrower: address
    ): (u64, u64, u128, u128) acquires T {
        let deal = borrow_global<T<Offered, Collateral>>(borrower);

        (
            deal.margin_call_rate,
            deal.current_rate,
            Dfinance::value(&deal.collateral),
            deal.offered_amount
        )
    }

    public fun check_deal<Offered, Collateral>(
        borrower: address
    ): u8 acquires T {

        if (!exists<T<Offered, Collateral>>(borrower)) {
            return DEAL_NOT_MADE
        };

        let cdp_deal = borrow_global<T<Offered, Collateral>>(borrower);
        let rate = Oracle::get_price<Offered, Collateral>();

        if (rate >= cdp_deal.margin_call_rate) {
            return DEAL_PAST_MARGIN_CALL
        };

        DEAL_OKAY
    }

    /// This method automatically takes money from balance of the
    /// borrower (right amount) and creates a deal placed on borrower's
    /// account.
    /// WARNING: This operation uses unprecise calculations due to the
    ///          limitations of u128 which can be overflown.
    ///
    /// Kind copyable is put intentionally, since all known coins have to
    /// be of Copyable kind. See 0x1::Coins;
    public fun take_offer<
        Offered: copyable,
        Collateral: copyable
    >(
        account: &signer,
        lender: address
    ) acquires Offer {

        let Offer {
            offered,
            collateral_multiplier,
            margin_call_at
        } = move_from<Offer<Offered, Collateral>>(lender);

        let rate : u64 = Oracle::get_price<Offered, Collateral>();
        let offered_amount = Dfinance::value<Offered>(&offered);
        let to_pay = offered_amount * (rate as u128) * (collateral_multiplier as u128) / 100 / 100000000;
        let margin_call_rate = rate * (margin_call_at as u64) / 100;
        let collateral = Account::withdraw_from_sender<Collateral>(account, to_pay);

        Account::deposit_to_sender<Offered>(account, offered);

        move_to<T<Offered, Collateral>>(account, T {
            lender,
            collateral,
            offered_amount,
            margin_call_rate,
            current_rate: rate
        });

        Event::emit<OfferTakenEvent<Offered, Collateral>>(
            account,
            OfferTakenEvent {
                lender,
                offered_amount,
                margin_call_rate,
                current_rate: rate,
                collateral_amount: to_pay,
                borrower: Signer::address_of(account),
            }
        );
    }

    /// CDP offer created by lender
    resource struct Offer<Offered, Collateral> {
        offered: Dfinance::T<Offered>,
        collateral_multiplier: u8,
        margin_call_at: u8
    }

    /// Creates a CDP deal
    public fun create_offer<
        Offered: copyable,
        Collateral: copyable
    >(
        account: &signer,
        offered: Dfinance::T<Offered>,
        collateral_multiplier: u8, // percent value * 100
        margin_call_at: u8         // percent value * 100
    ) {

        let offered_amount = Dfinance::value<Offered>(&offered);

        assert(Oracle::has_price<Offered, Collateral>(), ERR_NO_RATE);
        assert(offered_amount > 0, ERR_INCORRECT_ARGUMENT);

        // make sure that collateral mult is greater than 100 and
        // is greater than margin call (that's a must!)
        assert(
            collateral_multiplier > margin_call_at
            && collateral_multiplier > 100
        , ERR_INCORRECT_ARGUMENT);

        move_to<Offer<Offered, Collateral>>(
            account,
            Offer {
                offered,
                collateral_multiplier,
                margin_call_at
            }
        );

        Event::emit<OfferCreatedEvent<Offered, Collateral>>(
            account,
            OfferCreatedEvent {
                offered_amount,
                margin_call_at,
                collateral_multiplier,
                lender: Signer::address_of(account)
            }
        );
    }

    /// Check whether account has offer for given currency pairs
    public fun has_offer<Offered, Collateral>(account: address): bool {
        exists<Offer<Offered, Collateral>>(account)
    }

    /// Get tuple with offer details such as collateral_amount and margin_call
    public fun get_offer_details<Offered, Collateral>(account: address): (u128, u8, u8) acquires Offer {
        let offer = borrow_global<Offer<Offered, Collateral>>(account);

        (
            Dfinance::value<Offered>(&offer.offered),
            offer.collateral_multiplier,
            offer.margin_call_at
        )
    }
}
}
