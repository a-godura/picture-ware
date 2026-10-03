# Research: group trip photo sharing (October 2026)

Desk research into how people share photos from group trips today, what frustrates them,
and what comparable apps do. **This document records evidence and open questions only —
no product decisions have been made from it yet.**

## Method and limits

- Web search across tech press, Apple Community threads, vendor blogs and Hacker News.
- ~2,000 recent US App Store reviews of 7 apps (via Apple's public review feed), of which
  ~490 were rated 3★ or lower: Polarsteps, FindPenguins, Journi, Tripcast, Cluster,
  Homeroom, Google Photos.
- **Reddit could not be searched** with the available tools (blocked). App Store reviews skew
  toward complaints about broken apps; US store only. Vendor blogs are biased toward their
  own product but show which pains they're betting on.

## How people share trip photos today

| Option | What works | What people complain about |
|---|---|---|
| Group chat (iMessage, WhatsApp) | Zero setup | Compressed, buried in chat; WhatsApp's normal photo mode strips GPS |
| iCloud Shared Albums | Built into iPhone | Until June 2026: 2048px cap, hard for Android users. Ordered by upload time, not capture time. No map |
| Google Photos shared albums | Cross-platform | Albums disappearing, "can't share" errors, every contributor needs a Google account, no moderation, AI scanning |
| Polarsteps / FindPenguins / Journi | Trip on a map, travel books | Built for one traveler; GPS tracking drains battery and invents routes; viewers pushed to make accounts |
| Cluster / Homeroom / Tripcast | Private group albums | Uploads fail (especially bulk), notifications silently stop, no support |
| Link-based albums (Viallo, Yogile, Memoriia) | No account to contribute | Small/unproven (Viallo had 1 App Store rating) |

### Recent landscape changes
- **Apple, June 2026:** iCloud Shared Albums support full resolution and Android/Windows
  contributors via iCloud.com. Still no map or location features.
  ([MacRumors](https://www.macrumors.com/2026/06/08/apple-brings-icloud-shared-albums-to-android/))
- **Polarsteps "Travel Together":** up to 5 travelers on one trip; only the owner can change
  dates, remove buddies, delete the trip or make the book.
  ([Polarsteps support](https://support.polarsteps.com/hc/en-us/articles/24266789457170-What-is-Travel-Together))
- **Viallo:** one link, contribute without an account, automatic map and route per album,
  places photos without GPS using neighbouring photos' timestamps; free tier 2 albums,
  $5.99/mo Plus. ([vendor blog](https://www.viallo.app/blog/best-photo-sharing-app-travel))
- **Polarsteps, September 2026:** Follow the Money said it collected data on 23M users;
  Polarsteps disputes it was a leak (public profile data only).
  ([Polarsteps statement](https://www.polarsteps.com/comment-follow-the-money))

## Pain points (with evidence)

1. **Upload reliability is the #1 churn driver.** Cluster: "If you try to upload more than 8
   pics at a time it simply doesn't work"; uploads that "say they are uploading and they never
   do"; duplicate posts appearing days later; notifications silently stop so "no one knows when
   to login to see new photos".
2. **Making viewers create accounts.** FindPenguins: family "set up accounts in the app, can't
   see anything I've posted, and just get e-mails… trying to get them to use the app";
   "Requires an account to use; deleted". Polarsteps: friends can only like/comment "if they
   have the app".
3. **Couples and groups are poorly served.** Polarsteps 1★, July 2026 ("Trip with spouse app
   fail"): two phones couldn't both contribute to one trip, even after Travel Together shipped.
4. **Matching photos to places and days is tedious.** Polarsteps: photo "suggestions are always
   off", "more work than it's worth", scrolling 45 days back to reach today; place search can't
   find Kyoto or airports and renames places to their county.
5. **GPS tracking costs battery and accuracy.** "20–30% less usage on battery", phones heating
   up, phantom flights that can't be deleted.
6. **Privacy and safety.** "Aren't you afraid of being robbed?"; the 2026 Polarsteps scraping
   dispute; distrust of AI features ("partnering with some AI nonsense", Google AI scanning).
7. **Order by when photos were taken.** iCloud shared albums were "all but useless for…
   a vacation" because they sorted by upload time.
   ([HN](https://news.ycombinator.com/item?id=15329144))
8. **Fear of losing memories.** Cluster announced a shutdown and its archive export failed:
   "HOPING… no one loses their memories".
9. **Missing basics in group albums.** Cluster: "No sorting. No search. No filter (say, by
   person who uploads). No filtering by date."; admins want to restore photos others removed.
10. **Collecting is a chore with no reward.** The person gathering everyone's photos does the
    work and ends up with the same thing as everyone else. Social friction too (someone refusing
    to share the only group photo).

## Where GPS data survives sharing

| Path | GPS kept? |
|---|---|
| Original in the photo library | Yes (if location was on) |
| iMessage, AirDrop, email | Yes |
| WhatsApp normal photo mode | Usually stripped |
| WhatsApp "document" mode | Yes |
| iOS photo picker (PHPicker) | Location hidden unless the app reads `PHAsset.location` with library access |
| Screenshots, downloads, many social apps | No |

Sources: [sammapix](https://www.sammapix.com/blog/which-apps-strip-photo-metadata),
[KillEXIF](https://killexif.com/guides/whatsapp-instagram-telegram-photo-location/).

## Open questions this raises (not decided)

- What should happen to photos with no GPS: reject, estimate from neighbouring photos, ask the
  user to place them, or show them off-map?
- Who needs an account: viewers, contributors, both? Could a link do for some of them?
- Can members leave or be removed? Who controls the group?
- How exact should shared locations be (e.g. near someone's home)?
- How do photos get in with the least effort (e.g. suggesting photos taken during the trip)?
- Which map provider (Apple MapKit vs Google Maps), given cost and needed features?
- Is the differentiator the live, shared trip map during the trip, the after-trip collection,
  or both?
