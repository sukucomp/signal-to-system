import os, json, uuid
from azure.servicebus import ServiceBusClient, ServiceBusMessage

cs = os.environ["SERVICEBUS_CONNECTION_STRING"]
fixed_id = str(uuid.uuid4())

with ServiceBusClient.from_connection_string(cs) as client:
    with client.get_queue_sender("rfid-events") as sender:
        for i in range(5):
            msg = ServiceBusMessage(json.dumps({"test": "dedup", "attempt": i}))
            msg.message_id = fixed_id  # same ID every time
            sender.send_messages(msg)
            print(f"Sent attempt {i} with id={fixed_id}")
