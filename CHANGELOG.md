# Wanderer Auction 0.5.0

### New
- Sell everything: every item that brings more at the auction house than at a merchant, posted one after the other at the price and duration you choose. The game asks a gesture for each sale: a click on the button, a notch of the mouse wheel over it, or a key of yours (Key Bindings). A click on an item leaves it aside.
- An optimized price, the default: just under the first credible offer, weighed against the market's value of the last 14 days. Offers far too low (bait, sold low to be resold dearer) are left out.
- A History tab: an item's prices over the last 14 days in a small chart, its market value, today's cheapest, and whether now is a good time to sell.
- The prices' journal: what the looks for prices and the sales did, a line each, in a window beside the auction house.
- Better at a merchant (on by default, with Wanderer Bags 0.5.2): an item set aside for the auction house that would bring more at a merchant becomes junk, and is sold at the next merchant. Said in the chat each time.

### Changed
- Looking up the prices asks for all your items in one look, then the missing ones one by one; a line says where it is, what was found and what got no answer.
- Prices are never rounded: gold, silver and copper kept exactly.
- On the Buy page, a Shift+click on an item in your bags searches for it, even while the search box is written in.

### Fixed
- Posting an item no longer fails with an internal error (a starting bid is always given).
- The look for prices no longer stays stuck when the game does not answer.
