local ns = _G.NaowhForever

ns.GambleHelpText = [[HOW TO PLAY

SET UP A SESSION
Choose the pool, chat channel, join and leave words, and game mode in the Gamble window. The pool must be a whole number and represents a gold amount. Party and Raid chat are supported; choose the channel your group is using.

Select New Game to announce the session. Players, including the host, join by saying the configured join word in the selected chat. They can leave the lobby by saying the leave word. The host can use Last Call to remind the group, then select Start Rolling once at least two players have joined.

CLASSIC
Every joined player rolls from 1 to the pool amount using /roll. Use Announce Rolls to remind players who still need to roll and show the roll range.

When everyone has rolled, the player with the lowest roll pays the player with the highest roll the difference between those rolls. If either extreme is tied, the tied players reroll until both extremes have a single player.

DEATHROLL
After the host starts the game, two joined players are selected at random. Gamble announces the selected players, then announces which one was randomly chosen to roll first.

The first player rolls from 1 to the pool amount. The two selected players then alternate: after each roll, the next player rolls from 1 to the value just rolled. Use Announce Rolls to identify whose turn it is and the current roll range. The first player to roll 1 loses; the other player wins the pool.

ENDING A SESSION
The host can select Cancel Session at any time before the session completes. The cancellation is announced in chat and the session ends for everyone. Completed sessions cannot be cancelled.

Gamble only announces results; it does not transfer gold. Players settle any announced amount themselves.]]
