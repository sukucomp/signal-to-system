# signal-to-system
A collection of engineering notes exploring the intersection of physical systems and modern IT platforms. Covers RFID, edge systems, Kubernetes, and cloud infrastructure, with a focus on real-world deployment, reliability, and system integration across device-to-cloud architectures.

## Repository structure
```
signal-to-system/
├── README.md
│
├── rfid-to-windows-serial-port/      # Posts 5–7: local serial ingestion
│   ├── rfid-valid-uid-to-python.ino  # Arduino sketch (MFRC522 reader)
│   ├── rfid_serial_ingestor.py       # Python serial ingestor
│   ├── program.cs                    # C# serial ingestor
│   ├── SCHEMA.md                     # the fleet-ready event contract
│   └── README.md
│
├── rfid-to-azure-service-bus/        # Post 8: first cloud hop
│   ├── rfid-valid-uid-to-python.ino  # Arduino sketch (carried for self-containment)
│   ├── rfid-serial-ingestor-az-service-bus.py   # Python ingestor + Service Bus publish
│   ├── rfid-serial-ingestor-az-service-bus.cs   # C# ingestor + Service Bus publish
│   ├── RfidReader.csproj             # C# project (Azure.Messaging.ServiceBus)
│   ├── az-service-bus-dedup-test.py  # one-off: proves dedup collapses repeated MessageIds
│   ├── requirements.txt              # pyserial, azure-servicebus
│   ├── SCHEMA.md                     # event contract + cloud mapping section
│   └── README.md
│
└── db/
    └── table-growth-tracker.sql      # scratch SQL for tracking event-row growth
```

## Posts

| # | Title | LinkedIn | Code |
|---|-------|----------|------|
| 1 | Where Software Meets Physics: Why I'm Exploring RFID | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/where-software-meets-physics-why-im-exploring-rfid-balasubramaniam-0mitc/) | (no code) |
| 2 | Conversation with an RF Engineer | [`https://www.linkedin.com/...`](https://www.linkedin.com/posts/sureshkbalasubramaniam_signal-to-system-2-had-a-meaningful-catch-up-activity-7444809434901487616-h6LI/) | (no code) |
| 3 | RFID Deep-Dive: When the Student Is Ready | [`https://www.linkedin.com/...`](https://www.linkedin.com/posts/sureshkbalasubramaniam_rfid-lifelonglearning-engineering-activity-7448327381938888704-sfkE/) | (no code) |
| 4 | Why Your RFID Tag Isn't 'Instant' | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/why-your-rfid-tag-isnt-instant-quick-look-physics-balasubramaniam-i18kc/) | (no code) |
| 5 | RFID to Windows USB Port (Python) | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/rfid-windows-usb-port-comx-suresh-balasubramaniam-gmssc/) | [`01-serial-ingestor-python/`](./rfid-to-windows-serial-port/rfid_serial_ingestor.py) |
| 6 | From Prototype to Production: Python vs C# | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/from-prototype-production-python-vs-c-rfid-serial-balasubramaniam-haayc/) | [`02-serial-ingestor-c#/`](./rfid-to-windows-serial-port/program.cs) |
| 7 | From One Reader to a Fleet: Designing the 'Event Contract' | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-7-from-one-reader-fleet-designing-balasubramaniam-vd6mc/) | [`03-fleet-ready-schema/`](./rfid-to-windows-serial-port/rfid-valid-uid-to-python.ino) |
| 8 | First Cloud Hop - From Local Machine to Azure Service Bus | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-8-first-cloud-hop-from-local-machine-balasubramaniam-wvmrc/) | [`04-rfid-to-azure-service-bus/`](./rfid-to-azure-service-bus) |
| 9 | Who Owns the 'Air'? | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-9-who-owns-air-suresh-balasubramaniam-q0iqc/) | (no code) |
| 10 | The Loop Closes: From Queue to Cloud Table | [Read](https://www.linkedin.com/...) | [`rfid-to-azure-table-storage/`](./rfid-to-azure-table-storage) |


## About

Built by Suresh Balasubramaniam — Systems & Solutions Engineer
exploring the intersection of Electrical Engineering and modern IT
platforms. Each folder corresponds to one published post; the post
provides the narrative, the folder provides the working code.
