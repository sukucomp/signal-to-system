# signal-to-system
A collection of engineering notes exploring the intersection of physical systems and modern IT platforms. Covers RFID, edge systems, Kubernetes, and cloud infrastructure, with a focus on real-world deployment, reliability, and system integration across device-to-cloud architectures.

## Repository structure
```
signal-to-system/
├── README.md
├── rfid-event-consumer-containerized/
│   ├── .dockerignore
│   ├── .env.example
│   ├── config.py
│   ├── dockerfile
│   ├── readme.md
│   ├── requirements.txt
│   └── worker.py
├── rfid-to-azure-service-bus/
│   ├── az-service-bus-dedup-test.py
│   ├── README.md
│   ├── requirements.txt
│   ├── rfid-serial-ingestor-az-service-bus.cs
│   ├── rfid-serial-ingestor-az-service-bus.py
│   ├── rfid-valid-uid-to-python.ino
│   ├── RfidReader.csproj
│   └── SCHEMA.md
├── rfid-to-azure-table-storage/
│   ├── arduino/
│   │   └── rfid-valid-uid-to-python.ino
│   ├── az-function-consumer/
│   │   ├── host.json
│   │   ├── local.settings.json
│   │   ├── Program.cs
│   │   ├── rfid-event-consumer-az-function.cs
│   │   └── rfid-event-consumer-az-function.csproj
│   ├── host-ingestor/
│   │   ├── requirements.txt
│   │   ├── rfid-serial-ingestor-az-service-bus.cs
│   │   ├── rfid-serial-ingestor-az-service-bus.py
│   │   └── RfidReader.csproj
│   ├── README.md
│   └── SCHEMA.md
└── rfid-to-windows-serial-port/
    ├── program.cs
    ├── README.md
    ├── rfid_serial_ingestor.py
    ├── rfid-valid-uid-to-python.ino
    └── SCHEMA.md
```

## LinkedIn Posts

| # | Title | LinkedIn | Code |
|---|-------|----------|------|
| 1 | Where Software Meets Physics: Why I'm Exploring RFID | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/where-software-meets-physics-why-im-exploring-rfid-balasubramaniam-0mitc/) | (no code) |
| 2 | Conversation with an RF Engineer | [`https://www.linkedin.com/...`](https://www.linkedin.com/posts/sureshkbalasubramaniam_signal-to-system-2-had-a-meaningful-catch-up-activity-7444809434901487616-h6LI/) | (no code) |
| 3 | RFID Deep-Dive: When the Student Is Ready | [`https://www.linkedin.com/...`](https://www.linkedin.com/posts/sureshkbalasubramaniam_rfid-lifelonglearning-engineering-activity-7448327381938888704-sfkE/) | (no code) |
| 4 | Why Your RFID Tag Isn't 'Instant' | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/why-your-rfid-tag-isnt-instant-quick-look-physics-balasubramaniam-i18kc/) | (no code) |
| 5 | RFID to Windows USB Port (Python) | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/rfid-windows-usb-port-comx-suresh-balasubramaniam-gmssc/) | [`serial-ingestor-python/`](./rfid-to-windows-serial-port/rfid_serial_ingestor.py) |
| 6 | From Prototype to Production: Python vs C# | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/from-prototype-production-python-vs-c-rfid-serial-balasubramaniam-haayc/) | [`serial-ingestor-c#/`](./rfid-to-windows-serial-port/program.cs) |
| 7 | From One Reader to a Fleet: Designing the 'Event Contract' | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-7-from-one-reader-fleet-designing-balasubramaniam-vd6mc/) | [`fleet-ready-schema/`](./rfid-to-windows-serial-port/rfid-valid-uid-to-python.ino) |
| 8 | First Cloud Hop - From Local Machine to Azure Service Bus | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-8-first-cloud-hop-from-local-machine-balasubramaniam-wvmrc/) | [`rfid-to-azure-service-bus/`](./rfid-to-azure-service-bus) |
| 9 | Who Owns the 'Air'? | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-9-who-owns-air-suresh-balasubramaniam-q0iqc/) | (no code) |
| 10 | The Loop Closes: From Queue to Cloud Table | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-10-loop-closes-suresh-balasubramaniam-jwhvc/) | [`05-rfid-to-azure-table-storage/`](./rfid-to-azure-table-storage) |
| 11 | RF Polarization | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-11-rf-polarization-suresh-balasubramaniam-1lh3c/) | (no code) |
| 12 | The decibel & the dipole | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-12-decibel-dipole-what-simulator-made-balasubramaniam-zlssc/) | (no code) |
| 13 | Who Answers the Phone :) | [`https://www.linkedin.com/...`](https://www.linkedin.com/pulse/signal-system-13-who-answers-phone-suresh-balasubramaniam-oea7c/) | [`rfid-event-consumer-containerized`](https://github.com/sukucomp/signal-to-system/tree/main/rfid-event-consumer-containerized) |


## About

I am a Systems & Solutions Engineer
exploring the intersection of Electrical Engineering and modern IT
platforms. Each folder corresponds to one published post; the post
provides the narrative, the folder provides the working code.
