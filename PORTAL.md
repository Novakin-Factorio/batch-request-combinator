# Mod Portal text

## Short description

Turn an item signal into one exact robot-delivered batch: requests stop before loading, so the chests empty without refilling.

## Long description

# 🚂 Batch Request Combinator

Send an item signal to the combinator and logistic robots prepare one exact batch across its requester chests. The temporary requests are removed before `READY` turns on, so loading can empty the chests without asking robots to refill them. `COMPLETE` turns on when the managed chests and inserter hands are empty.

Built for robot-fed train stations, it also works with other circuit-controlled loading setups. Single and Parallel modes can finish supported partial inserter hands before the next batch. No train-control mod is required.

![Batch Request Combinator shown in all four directions](https://raw.githubusercontent.com/Novakin-Factorio/batch-request-combinator/main/assets/batch-request-combinator-four-directions.png)

The combinator uses an electric-blue mechanical counter-drum design. The bundled requester has a matching electric-blue robot-door animation.

> **Experimental:** This mod is still being tested and refined. Back up important saves and try it in a safe setup before relying on it in an important factory.

## ✨ The gameplay loop

1. Your circuit sends the items and quantities for one batch.
2. Logistic robots stage the items across the connected requester chests.
3. When the exact amount is ready and robot activity has stopped, the temporary requests are removed.
4. `READY` turns on, so your loading inserters can empty the chests without triggering replacement deliveries.
5. `COMPLETE` turns on after the managed chests and inserter hands are empty.
6. Return the input to zero, wait for `ARMED`, and send the next batch.

The captured batch does not resize while it is running. This keeps one request, one loading cycle, and one result clearly separated from the next.

## 🔧 Quick setup

1. Connect your item signals to the combinator's input side.
2. Connect the requester chests and their loading inserters to the output side.
3. While input is zero, use **Review inserter setup…** to preview and confirm the standard `READY` settings, or configure the inserters manually to run when `READY > 0`.
4. Choose Follow or Snapshot and a tail mode in the combinator window.
5. Send a nonzero item request.

Red wire, green wire, or both are supported. Duplicate red and green paths count only once. The requested amount is the final total across all managed chests, not an amount requested separately from every chest.

## 🧩 Compatibility and current status

- Factorio 2.1; Base is required and Quality is optional.
- Works with the included exact requester, ordinary requester chests, and compatible modded requester chests. Buffer, provider, and storage chests are not supported.
- Does not require Cybersyn, LTN, Wagon Split, or another train-control mod.
- Do not enable the older standalone `batch-combinator-requester` beside this mod because both include the same requester entities.

Save/reload during active batches, cargo-size overdelivery to ordinary requester chests, multiplayer, other languages or UI scales, more complex factory layouts, and very large factories remain experimental; try those setups in a safe save first. The current release was checked in Factorio 2.1.17 in English at 100% UI scale.

## 📦 Two requester choices

### Batch-Combinator Requester

The included electric-blue requester asks robots for the exact amount, without normal cargo-size overdelivery. Its capacity is a startup setting from 48 to 5,000 slots, defaults to 5,000, and stays the same at every quality level.

Use it when you want the simplest and strictest staging behavior.

### Compatible ordinary requester

Ordinary requester chests are also supported. Robots may briefly deliver extra items because of cargo size. Loading stays off while those items return to logistic storage, and `READY` appears only when every chest holds its exact share and robot activity has stopped. Keep logistic robots and storage space available for the return trip.

## 🔄 Follow or Snapshot

- **Follow:** Returning the input to zero during `REQUESTING`, `SETTLING`, or `READY` stops the active batch. Optional automatic cleanup can then return that batch's remaining items to logistic storage. After normal `COMPLETE`, zero rearms the combinator.
- **Snapshot:** Hold the request until the combinator leaves `ARMED`. The captured batch then continues even after the input returns to zero.

Signal changes never resize an active batch or queue another one. Wait for `ARMED` before sending the next request.

## 🪶 Choose how inserter tails are handled

A tail is the final partial inserter hand left when a batch does not divide evenly into full swings.

- **No tail flush:** The automatic batch cycle leaves inserter settings alone. Use it when your hand-size setup already avoids partial loads or when you want full manual control. The separate confirmed setup action can still apply the standard `READY` configuration.
- **Single tail inserter:** Use this when several loading lanes feed the same destination, such as one wagon. It requires exactly one connected loading inserter for each requester chest.
- **Parallel tail inserters:** Use this when lanes feed separate destinations. It requires at least one loading inserter per chest and can use several inserters pulling from the same chest. This is the default for new combinators.

When several Parallel inserters share a chest, they must move the same number of items per swing for every item in the batch. Item stack sizes affect this check, so the mod checks it when the batch starts. Usually, give those inserters the same supported **Stack size override**.

Single and Parallel briefly adjust **Stack size override** when releasing a final partial hand, then restore its previous value. Every controlled inserter must start empty and run when `READY > 0`.

While `ARMED` with zero input, **Review inserter setup…** shows how many eligible loading inserters will be changed and asks for confirmation before changing anything. It configures them to run on `READY`, turns off conflicting circuit and logistic-network controls, clears filters, and keeps existing stack-size overrides. It changes only inserters already wired to the combinator and picking up from its requester chests; it does not add wires, rotate inserters, or change pickup targets. If setup cannot finish, it restores every setting it can and tells you which inserter still needs attention.

## 🚦 Clear status and recovery

Dedicated circuit signals expose `ARMED`, `REQUESTING`, `SETTLING`, `READY`, `COMPLETE`, `WARNING`, `ERROR`, and `ABORTED`. Loading should use `READY > 0`.

The combinator window shows the current state, progress, requested items, each chest's share, and clear recovery instructions. Error codes and detailed rules remain available under **Technical details**.

During an active batch, **Abort batch** safely removes temporary requests created by this combinator and restores temporary settings. In an error, the same action becomes **Reset batch**. Reset never deletes or directly moves physical chest contents.

While the combinator is `ARMED` with zero input, **Maintenance** can preview and drain connected requester chests through normal robot logistics. Optional Follow cleanup can do the same automatically when an active Follow request returns to zero. Both paths restore each chest's previous **Trash unrequested** setting and wait safely if robots or logistic storage are unavailable.

## ⚠️ Important limits

- `COMPLETE` proves that the managed requester chests and monitored inserter hands are empty. It does not verify wagon capacity, train identity, train schedules, or the final destination.
- Requester chests must not have competing active requests or contain unrelated items when a batch begins.
- Do not move, replace, merge, split, or rewire managed entities during an active batch. Reset to zero, reconnect the setup, wait for `ARMED`, and then send a fresh request.
- Cleanup needs logistic coverage, available robots, and free logistic storage. Items already moved to storage are not automatically returned.
- Before disabling or removing the mod, return every combinator to `ARMED` and save so temporary requests and settings can be restored.

## ⚡ Performance

The **Batch processing interval** map setting ranges from 1 to 60 ticks and defaults to 12. Lower values make batches react sooner and use more processing time; higher values react more slowly and use less.

## 🛠️ Unlocks and recipes

The **Batch Request Combinator** technology requires **Circuit network** and **Logistic system**. It costs 150 cycles of Automation, Logistic, Chemical, and Utility science packs at 30 seconds per cycle and unlocks both items:

- **Batch Request Combinator:** 1 Decider combinator, 5 Advanced circuits, and 2 Processing units; 2-second craft.
- **Batch-Combinator Requester:** 1 Requester chest, 5 Advanced circuits, and 2 Processing units; 2-second craft.

## 🆕 What changed in 0.1.2

- Added a preview-and-confirm action for the standard `READY` inserter settings.
- Single now requires exactly one eligible inserter per chest during setup; Parallel and No-tail allow several.
- Setup refuses inserters already in use by another batch or cleanup and identifies any inserter whose previous settings could not be restored after a failed change.
- Improved interrupted-cleanup recovery and polished the confirmation dialog.

## ❓ Help and support

For full setup details and troubleshooting, read the [complete guide](https://github.com/Novakin-Factorio/batch-request-combinator#readme). Bugs and compatibility problems can be reported on the [issue tracker](https://github.com/Novakin-Factorio/batch-request-combinator/issues).

## 🙏 Credits and license

Released under the MIT License.

Generative AI assisted with code, testing, documentation, and the packaged thumbnail artwork. All changes and final assets were reviewed and approved by the maintainer.
