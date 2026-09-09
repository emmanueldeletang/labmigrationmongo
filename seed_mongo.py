import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from bson import ObjectId
from pymongo import ASCENDING, MongoClient


def load_parameters():
    parameters_path = Path(__file__).with_name("parameters.json")
    try:
        with parameters_path.open(encoding="utf-8") as parameters_file:
            parameters = json.load(parameters_file)
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Unable to load MongoDB parameters from {parameters_path}") from error
    required = (
        "MongoUri",
        "MongoDatabase",
        "MongoServerSelectionTimeoutMs",
        "TaskStatuses",
        "SeedUserCount",
        "SeedProjectCount",
        "SeedTasksPerProject",
    )
    missing = [key for key in required if parameters.get(key) in (None, "", [])]
    if missing:
        raise RuntimeError(f"Missing parameters in {parameters_path}: {', '.join(missing)}")
    return parameters


def seed_database():
    parameters = load_parameters()
    print(f"Seeding MongoDB database '{parameters['MongoDatabase']}' at '{parameters['MongoUri']}'...")
    client = MongoClient(
        parameters["MongoUri"],
        serverSelectionTimeoutMS=int(parameters["MongoServerSelectionTimeoutMs"]),
    )
    client.admin.command("ping")
    database = client[parameters["MongoDatabase"]]

    database.users.delete_many({})
    database.projects.delete_many({})
    database.tasks.delete_many({})

    now = datetime.now(timezone.utc)
    users = [
        {
            "_id": ObjectId(),
            "name": f"Team Member {number:02d}",
            "email": f"user{number:02d}@example.com",
            "created_at": now,
        }
        for number in range(1, int(parameters["SeedUserCount"]) + 1)
    ]
    projects = [
        {
            "_id": ObjectId(),
            "name": f"Project {number}",
            "description": f"Delivery workstream for project {number}.",
            "created_at": now,
        }
        for number in range(1, int(parameters["SeedProjectCount"]) + 1)
    ]
    database.users.insert_many(users)
    database.projects.insert_many(projects)

    tasks = []
    for project_number, project in enumerate(projects, start=1):
        task_count = int(parameters["SeedTasksPerProject"])
        task_ids = [ObjectId() for _ in range(task_count)]
        for index, task_id in enumerate(task_ids):
            dependencies = []
            if index > 0 and index % 4 == 0:
                dependencies.append(task_ids[index - 1])
            if index > 1 and index % 10 == 0:
                dependencies.append(task_ids[index - 2])
            created_at = now - timedelta(days=task_count - index)
            tasks.append(
                {
                    "_id": task_id,
                    "title": f"Project {project_number} Task {index + 1:03d}",
                    "description": f"Complete deliverable {index + 1} for project {project_number}.",
                    "project_id": project["_id"],
                    "assigned_user_id": users[(index + project_number - 1) % len(users)]["_id"],
                    "duration_days": (index % 5) + 1,
                    "status": parameters["TaskStatuses"][index % len(parameters["TaskStatuses"])],
                    "dependencies": dependencies,
                    "can_run_parallel": index % 3 != 0 and not dependencies,
                    "created_at": created_at,
                    "updated_at": created_at,
                }
            )

    database.tasks.insert_many(tasks, ordered=False)
    database.tasks.create_index([("project_id", ASCENDING)])
    database.tasks.create_index([("assigned_user_id", ASCENDING)])
    database.tasks.create_index([("status", ASCENDING)])
    database.tasks.create_index([("dependencies", ASCENDING)])

    print(
        f"Seeded {database.users.count_documents({})} users, "
        f"{database.projects.count_documents({})} projects, and "
        f"{database.tasks.count_documents({})} tasks."
    )
    client.close()


if __name__ == "__main__":
    seed_database()
