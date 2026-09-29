import WAKit

/// Everyone in the demo. UK numbers are in Ofcom's 07700 900xxx range, reserved for fiction.
/// Avatars are `avatars/<jid>.jpg`; a person without one shows initials.
enum Cast {
    static let me = Person("447700900100", nil, push: "Sam")

    static let maya = Person("447700900201", "Maya Chen")
    static let jonas = Person("4915112345601", "Jonas Weber")
    static let ines = Person("351912345602", "Inês Duarte")
    static let priya = Person("447700900203", "Priya Raman")
    static let dev = Person("447700900204", "Dev Kapoor")
    static let lena = Person("447700900205", "Lena Novak")
    static let tom = Person("447700900206", "Tom Okafor")
    static let mum = Person("447700900207", "Mum", push: "Helen")
    static let dad = Person("447700900208", "Dad", push: "Mark")
    static let nora = Person("447700900209", "Nora Rivera")
    static let ollie = Person("447700900211", "Ollie Grant")
    static let hana = Person("447700900212", "Hana Sato")
    static let ben = Person("447700900213", "Ben Hughes")
    static let aisha = Person("447700900214", "Aisha Bello")
    static let rafa = Person("351912345615", "Rafa Costa")
    static let kai = Person("447700900220", "Kai Brennan")
    static let sofia = Person("393331234567", "Sofia Marchetti")
    // Not in the address book: shown by push name.
    static let kofi = Person("447700900210", nil, push: "Kofi A.")
    static let marcus = Person("447700900216", nil, push: "Marcus")
    static let jay = Person("447700900217", nil, push: "Jay 🧤")

    // Saved, but no chat yet (⌘N).
    static let idle = [
        Person("447700900218", "Alex Morgan"),
        Person("33612345678", "Chloé Martin"),
        Person("447700900219", "Grandma"),
    ]

    static let northside = Person("442079460101", nil, push: "Northside Coffee Roasters")
    static let spoke = Person("442079460102", nil, push: "Spoke & Chain Cycles")
    static let fern = Person("442079460103", nil, push: "Fern & Fig")
    static let dental = Person("442079460104", nil, push: "Harbour Dental")
    static let parcelly = Person("442079460105", nil, push: "Parcelly")
    static let tejo = Person("351213000106", nil, push: "Tejo Stays")

    static let businesses = [northside, spoke, fern, dental, parcelly, tejo]
}

func buildChats(_ media: MediaLibrary) throws -> [Chat] {
    let me = Cast.me
    var chats: [Chat] = []

    do {
        let c = Chat(group: 1, "Family 🏡", [Cast.mum, Cast.dad, Cast.nora], admins: [Cast.mum])
        c.pin = 1
        c.unread = 3
        c.day(3, "09:12")
        c.send(Cast.dad, "Morning all. Boiler engineer is coming next week, somewhere between 8 and 12 apparently")
        c.send(Cast.nora, "the famous four hour window")
        c.send(Cast.mum, "I'll be in, don't worry")
        c.day(2, "15:30")
        c.send(Cast.nora, "Biscuit has entered his cosy era", kind: .image, media: try media.photo("biscuit-blanket.jpg"),
               reactions: [(Cast.mum, "❤️"), (Cast.dad, "😂"), (me, "😍")])
        c.wait(3)
        let ghost = c.send(me, "He looks like he's about to tell us a ghost story")
        c.send(Cast.nora, "he IS the ghost story", reply: ghost)
        c.wait(12)
        c.send(Cast.dad, "That's my good blanket")
        c.day(1, "12:10")
        c.send(Cast.mum, "First proper harvest from the allotment 🍓", kind: .image, media: try media.photo("strawberries.jpg"),
               reactions: [(Cast.nora, "🤤")])
        c.send(me, "Mum those look better than the supermarket ones")
        c.send(Cast.mum, "Because they ARE better. I'll save you a punnet")
        c.wait(40)
        let lunch = c.send(Cast.mum, kind: .poll, poll: BridgePoll(question: "Sunday lunch next week?",
                                                                    options: ["Roast at ours", "Pub", "Can't make it 😢"], selectableCount: 1))
        c.vote(lunch, Cast.dad, "Roast at ours")
        c.vote(lunch, me, "Roast at ours")
        c.vote(lunch, Cast.nora, "Pub")
        c.send(Cast.nora, "pub has a fire though. just saying")
        c.day(0, "08:51")
        c.send(Cast.mum, kind: .voice, media: try media.voice("mum-voice.m4a"))
        c.wait(6)
        c.send(Cast.dad, "Found him.", kind: .image, media: try media.photo("biscuit-bed.jpg"))
        c.send(Cast.nora, "😂😂 he's taken over your room Sam")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.maya)
        c.pin = 2
        c.unread = 2
        c.day(2, "11:20")
        c.send(Cast.maya, "are you still coming to the market tomorrow?")
        c.send(me, "Yes! 10ish?")
        c.send(Cast.maya, "perfect, I'll grab coffees")
        c.day(1, "19:48")
        c.send(Cast.maya, "attempted the salad from that recipe you sent. verdict: would chop again", kind: .image,
               media: try media.photo("dinner.jpg"), reactions: [(me, "😍")])
        c.wait(4)
        c.send(me, "Look at you!! How was the dressing?")
        c.send(Cast.maya, "the secret is *too much* lime")
        c.day(0, "08:14")
        c.send(Cast.maya, "ok cinema tonight: 7:45 showing, I booked two seats in row F")
        c.send(me, "Amazing, I'll leave the office at 7")
        c.send(me, "Wait is it the three hour one")
        c.send(Cast.maya, "it's 2h 49m, you'll survive", reactions: [(me, "😂")])
        c.day(0, "09:38")
        c.send(Cast.maya, kind: .voice, media: try media.voice("maya-voice.m4a"))
        c.send(Cast.maya, "also you owe me a popcorn from last time")
        chats.append(c)
    }

    do {
        let c = Chat(group: 2, "Lisbon 🇵🇹", [Cast.maya, Cast.ines, Cast.rafa, Cast.priya], admins: [me])
        c.pin = 3
        c.day(6, "20:14")
        c.send(me, "Ok it's official, flights booked ✈️ 9th to the 13th")
        c.send(Cast.priya, "YESSS")
        c.send(Cast.maya, "Inês, we're going to need every single recommendation you have")
        c.send(Cast.ines, "Oh you have no idea what's coming. I'm making a list")
        c.day(5, "09:30")
        let plan = c.send(me, "First draft, edits welcome", kind: .document, media: try media.pdf("Lisbon itinerary.pdf"))
        c.wait(20)
        c.send(Cast.ines, "Looks good! Swap Belém to the morning, the queue for the pastéis is much shorter before 11",
               reply: plan, edited: true)
        c.send(me, "Done 👍")
        c.day(3, "13:02")
        c.send(Cast.ines, "Your ride to the castle. Get on at Martim Moniz or you'll never get a seat", kind: .image,
               media: try media.photo("lisbon-tram.jpg"), reactions: [(Cast.maya, "🤩"), (Cast.priya, "🤩")])
        c.send(Cast.ines, "and this is the street the flat is on", kind: .image, media: try media.photo("lisbon-alley.jpg"))
        c.send(Cast.priya, "I would like to live there permanently please")
        c.day(1, "21:40")
        let sintra = c.send(me, kind: .poll, poll: BridgePoll(question: "Sintra: which day?",
                                                              options: ["Saturday", "Sunday", "Skip it"], selectableCount: 1))
        c.vote(sintra, me, "Saturday")
        c.vote(sintra, Cast.maya, "Saturday")
        c.vote(sintra, Cast.priya, "Saturday")
        c.vote(sintra, Cast.ines, "Sunday")
        c.wait(15)
        c.send(Cast.rafa, "Saturday. Take the 8:50 train from Rossio, trust me")
        c.day(0, "09:02")
        c.send(Cast.ines, kind: .location, location: BridgeLocation(latitude: 38.7106, longitude: -9.1436, name: "Taberna da Rua das Flores",
                                                                    address: "Rua das Flores 103, Lisboa", isLive: false))
        c.send(Cast.ines, "Dinner on the first night. No reservations, so be there by 7:30")
        c.send(Cast.maya, "noted. arriving at 7:15 with a fork")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.dev)
        c.day(0, "08:47")
        c.send(Cast.dev, "did you see the build is red again")
        c.send(me, "Yeah, it's the date formatting test. It assumes the machine is in UTC")
        c.send(Cast.dev, "classic. the fix is one line:")
        c.send(Cast.dev, "```\nformatter.timeZone = TimeZone(identifier: \"UTC\")\n```")
        c.wait(2)
        c.send(me, "Ship it", reactions: [(Cast.dev, "🚢")])
        c.wait(8)
        c.send(Cast.dev, "merged. lunch? the ramen place on Exmouth Market")
        c.send(me, "Yes, 12:45")
        chats.append(c)
    }

    do {
        let c = Chat(group: 3, "Design Crit", [Cast.sofia, Cast.dev, Cast.kai], admins: [Cast.sofia])
        c.day(1, "15:10")
        c.send(Cast.sofia, "Moodboard for the onboarding refresh. Leaning warmer, less blue", kind: .image,
               media: try media.photo("design-desk.jpg"), reactions: [(Cast.kai, "🔥"), (me, "🔥")])
        c.send(Cast.dev, "Love it. The poster in the corner is doing a lot of work")
        let gradient = c.send(Cast.kai, "Can we keep the illustrations but drop the gradient?")
        c.send(Cast.sofia, "Yes, flat colour plus the grain texture", reply: gradient)
        c.send(me, "I'll mock up the sign-in screen both ways by tomorrow")
        c.send(Cast.sofia, "🙏")
        c.day(1, "16:02")
        c.send(Cast.dev, "Reminder: crit moved to 11:30 tomorrow, same room")
        chats.append(c)
    }

    do {
        let c = Chat(group: 5, "5-a-side ⚽️", [Cast.tom, Cast.ben, Cast.marcus, Cast.jay], admins: [Cast.ben])
        c.muted = true
        c.unread = 14
        c.day(3, "21:30")
        c.send(me, "Good game tonight, my legs are gone")
        c.send(Cast.tom, "that last goal though 🔥")
        c.day(0, "07:31")
        c.send(Cast.ben, "Who's in this week?")
        c.send(Cast.tom, "in")
        c.send(Cast.marcus, "in")
        c.send(Cast.jay, "in, bringing the new gloves")
        c.wait(30)
        c.send(Cast.ben, "need 2 more")
        c.send(Cast.tom, "Sam??")
        c.send(Cast.tom, "SAM")
        c.send(Cast.marcus, "he's got us on mute hasn't he 😂")
        c.wait(25)
        c.send(Cast.ben, "7:30, same pitch. Bibs are in my car")
        c.send(Cast.jay, "who's got the ball")
        c.send(Cast.tom, "me")
        c.send(Cast.ben, "£6 each for the pitch, pay me whenever")
        c.send(Cast.marcus, "👍")
        c.day(0, "09:12")
        c.send(Cast.jay, "anyone got a spare shin pad, I've lost one. again")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.jonas)
        c.day(1, "08:12")
        c.send(Cast.jonas, "Made it to the top. Worth every step", kind: .image, media: try media.photo("fjord.jpg"))
        c.send(Cast.jonas, "Last night's campsite. Minus six. Never again (until next time)", kind: .image,
               media: try media.photo("snow-camp.jpg"))
        c.wait(25)
        c.send(me, "This is unreal. Where is this?")
        c.send(Cast.jonas, "Preikestolen, then two nights further north")
        c.send(me, "Adding it to the list. Beers when you're back?")
        c.send(Cast.jonas, "Obviously 🍻", reactions: [(me, "👍")])
        chats.append(c)
    }

    do {
        let c = Chat(group: 4, "Flat 3B 🏠", [Cast.ollie, Cast.hana], admins: [Cast.ollie])
        c.day(2, "19:00")
        c.send(Cast.ollie, "Bills for September:\n\n• Energy £84.20\n• Internet £32.00\n• Water £27.50\n\n£47.90 each, same account as usual")
        c.send(Cast.hana, "Sent ✅")
        c.send(me, "Sent, thanks for sorting!")
        c.wait(45)
        c.send(Cast.hana, "Also who has the good scissors")
        c.send(Cast.ollie, "Not me")
        c.send(me, "…might be in my room. Returning them now")
        c.day(1, "22:15")
        c.send(Cast.hana, "Anyone mind if my sister stays next weekend?")
        c.send(Cast.ollie, "Course not")
        c.send(me, "Of course! Tell her the shower takes two minutes to warm up")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.priya)
        c.day(1, "18:30")
        let flat = c.send(Cast.priya, "Viewing tomorrow!! Look at the light", kind: .image, media: try media.photo("flat-dining.jpg"))
        c.send(me, "Oh that's lovely. Which area?")
        c.send(Cast.priya, "Hackney, five minutes from the overground")
        c.send(me, "Those chairs are coming with you, right?", reply: flat)
        c.send(Cast.priya, "They're staying 😭 but the landlord said I can keep the table")
        c.send(Cast.priya, "Will you come with me? I need someone to ask sensible questions")
        c.send(me, "Of course. Send me the time")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.kofi)
        c.day(2, "10:02")
        c.send(Cast.kofi, "Hi, saw your listing for the road bike. Is it still available?")
        c.wait(20)
        c.send(me, "Hi Kofi, yes it is!")
        c.send(Cast.kofi, "Great. Would you take £280?")
        c.send(me, "Could do £300, it's just been serviced")
        c.send(Cast.kofi, "Deal. Could I come and see it tomorrow, around 6:30?")
        c.send(me, "Perfect, I'll send you the address")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.ines)
        c.day(4, "20:51")
        c.send(Cast.ines, "Sam! Rafa says you're finally coming to Lisbon 🎉")
        c.send(me, "Finally! Can't wait to see you both")
        c.send(Cast.ines, "I'll put my list in the group. Do you like fado?")
        c.send(me, "Never been, but I'm in")
        c.send(Cast.ines, "Perfect. I know a tiny place in Alfama, I'll book for the Friday")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.lena)
        c.markedUnread = true
        c.day(4, "07:40")
        c.send(Cast.lena, "10k at the weekend?")
        c.send(me, "Yes, if we go after 9")
        c.send(Cast.lena, "Deal. Canal loop?")
        c.send(me, "Canal loop 🏃")
        c.wait(30)
        c.send(Cast.lena, "Also, happy early birthday!! I'm away on the day so consider this your official 🎂")
        chats.append(c)
    }

    do {
        let c = Chat(group: 6, "Saturday Hikes ⛰️", [Cast.jonas, Cast.lena, Cast.ben], admins: [Cast.lena])
        c.day(8, "19:20")
        c.send(Cast.lena, "Seven Sisters next time? Train from Victoria at 8:47")
        c.send(Cast.jonas, "I'm in Norway 😭 go without me")
        c.send(Cast.ben, "in")
        c.send(me, "In! I'll bring snacks")
        c.send(Cast.lena, kind: .location, location: BridgeLocation(latitude: 50.7760, longitude: 0.1508, name: "Seven Sisters Country Park",
                                                                    address: "Exceat, Seaford BN25 4AD", isLive: false))
        chats.append(c)
    }

    do {
        let c = Chat(Cast.tom)
        c.day(6, "22:03")
        c.send(Cast.tom, "mate you left your jacket at mine")
        c.send(me, "Ah, I wondered where that went. I'll grab it at football")
        c.send(Cast.tom, "👍")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.nora)
        c.day(7, "21:15")
        c.send(Cast.nora, "Ok Mum's 60th. Surprise dinner or weekend away?")
        c.send(me, "Weekend away. She's been talking about the Lake District for years")
        c.send(Cast.nora, "YES. I'll look at cottages. Don't say anything in the family chat")
        c.send(me, "🤐")
        c.wait(50)
        c.send(Cast.nora, "found one with a hot tub and a view of Derwentwater")
        chats.append(c)
    }

    do {
        let c = Chat(group: 7, "Book Club 📚", [Cast.aisha, Cast.lena, Cast.priya], admins: [Cast.aisha])
        c.archived = true
        c.day(20, "18:05")
        c.send(Cast.aisha, "Next month: _Klara and the Sun_. Meeting at mine")
        c.send(Cast.priya, "Halfway through already 🤓")
        c.send(me, "Just ordered it")
        chats.append(c)
    }

    // Businesses

    do {
        let c = Chat(Cast.northside)
        c.unread = 2
        c.day(9, "10:12")
        c.send(me, "Hi! Could I switch my subscription to whole beans instead of ground?")
        c.send(Cast.northside, "Done! Future orders will be whole bean ☕")
        c.day(0, "07:58")
        c.send(Cast.northside, "Morning Sam ☀️ Your October subscription ships tomorrow: 2 × 250g Huila, Colombia (washed). Tasting notes: red apple, panela, cocoa.")
        c.send(Cast.northside, "Fresh out of the roaster this morning", kind: .image, media: try media.photo("coffee-beans.jpg"))
        chats.append(c)
    }

    do {
        let c = Chat(Cast.spoke)
        c.day(1, "16:45")
        c.send(Cast.spoke, "Hi Sam, your bike is ready for collection. We replaced the chain and brake pads and trued the rear wheel. Total £68.00.")
        c.send(me, "Brilliant, I'll swing by after work")
        c.send(Cast.spoke, "Great, we're open until 7 👍")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.parcelly)
        c.day(2, "08:05")
        c.send(Cast.parcelly, "📦 Your parcel from Fern & Fig is out for delivery. Estimated arrival 11:30–13:30.")
        c.day(2, "12:48")
        c.send(Cast.parcelly, "✅ Delivered. Left with your neighbour at No. 12.")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.tejo)
        c.day(3, "14:00")
        c.send(Cast.tejo, "Olá Sam! Thank you for booking Casa Alfama with Tejo Stays. Check-in is from 15:00 on your arrival day, and we'll send your door code 24 hours before.")
        c.wait(10)
        c.send(me, "Obrigado! Is there somewhere to leave bags if we arrive early?")
        c.send(Cast.tejo, "Of course. Our office on Rua dos Remédios opens at 9:00 and you can leave bags there for free 🧳")
        c.send(Cast.tejo, kind: .location, location: BridgeLocation(latitude: 38.7118, longitude: -9.1297, name: "Casa Alfama",
                                                                    address: "Rua de São Miguel 24, 1100-544 Lisboa", isLive: false))
        chats.append(c)
    }

    do {
        let c = Chat(Cast.fern)
        c.day(3, "17:20")
        c.send(Cast.fern, "Your order #FF-2291 is on its way: Monstera deliciosa (large) and a terracotta pot 🪴 Care tips are in the box!")
        c.send(me, "Can't wait! Any tips for a room without much light?")
        c.send(Cast.fern, "Monstera copes well with medium light. Keep it a metre or two from a window and water when the top 5 cm of soil is dry.")
        chats.append(c)
    }

    do {
        let c = Chat(Cast.dental)
        c.day(5, "09:00")
        c.send(Cast.dental, "Hi Sam, this is a reminder of your check-up with Dr Patel on 6 October at 08:40. Reply 1 to confirm or 2 to reschedule.")
        c.wait(35)
        c.send(me, "1")
        c.send(Cast.dental, "Thanks Sam, you're confirmed. See you soon! 🦷")
        chats.append(c)
    }

    return chats
}
