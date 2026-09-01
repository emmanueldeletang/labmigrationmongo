import json
from datetime import datetime, timezone
from pathlib import Path

from bson import ObjectId
from bson.errors import InvalidId
from flask import Flask, abort, flash, jsonify, redirect, render_template, request, url_for
from pymongo import MongoClient


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
        "FlaskHost",
        "FlaskPort",
        "FlaskSecretKey",
        "TaskStatuses",
    )
    missing = [key for key in required if parameters.get(key) in (None, "", [])]
    if missing:
        raise RuntimeError(f"Missing parameters in {parameters_path}: {', '.join(missing)}")
    return parameters

PARAMETERS = load_parameters()
DATABASE_NAME = PARAMETERS["MongoDatabase"]
VALID_STATUSES = tuple(PARAMETERS["TaskStatuses"])
app = Flask(__name__)
app.secret_key = PARAMETERS["FlaskSecretKey"]
mongo_client = MongoClient(
    PARAMETERS["MongoUri"],
    serverSelectionTimeoutMS=int(PARAMETERS["MongoServerSelectionTimeoutMs"]),
)
db = mongo_client[DATABASE_NAME]


def parse_object_id(value, field_name="id"):
    try:
        return ObjectId(value)
    except (InvalidId, TypeError):
        raise ValueError(f"Invalid {field_name}.") from None


def serialize(value):
    if isinstance(value, ObjectId):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, list):
        return [serialize(item) for item in value]
    if isinstance(value, dict):
        return {key: serialize(item) for key, item in value.items()}
    return value


def task_payload(source, partial=False):
    allowed = {
        "title",
        "description",
        "project_id",
        "assigned_user_id",
        "duration_days",
        "status",
        "dependencies",
        "can_run_parallel",
    }
    payload = {key: source[key] for key in allowed if key in source}
    required = {"title", "project_id", "assigned_user_id"}
    if not partial and not required.issubset(payload):
        raise ValueError("title, project_id, and assigned_user_id are required.")

    if "title" in payload:
        payload["title"] = str(payload["title"]).strip()
        if not payload["title"]:
            raise ValueError("title cannot be empty.")
    if "description" in payload:
        payload["description"] = str(payload["description"]).strip()
    if "project_id" in payload:
        payload["project_id"] = parse_object_id(payload["project_id"], "project_id")
        if not db.projects.find_one({"_id": payload["project_id"]}):
            raise ValueError("project_id does not reference an existing project.")
    if "assigned_user_id" in payload:
        payload["assigned_user_id"] = parse_object_id(
            payload["assigned_user_id"], "assigned_user_id"
        )
        if not db.users.find_one({"_id": payload["assigned_user_id"]}):
            raise ValueError("assigned_user_id does not reference an existing user.")
    if "duration_days" in payload:
        try:
            payload["duration_days"] = int(payload["duration_days"])
        except (TypeError, ValueError):
            raise ValueError("duration_days must be an integer from 1 to 5.") from None
        if payload["duration_days"] not in range(1, 6):
            raise ValueError("duration_days must be an integer from 1 to 5.")
    elif not partial:
        payload["duration_days"] = 1
    if "status" in payload and payload["status"] not in VALID_STATUSES:
        raise ValueError(f"status must be one of: {', '.join(VALID_STATUSES)}.")
    elif "status" not in payload and not partial:
        payload["status"] = "todo"
    if "dependencies" in payload:
        dependencies = payload["dependencies"]
        if isinstance(dependencies, str):
            dependencies = [item.strip() for item in dependencies.split(",") if item.strip()]
        if not isinstance(dependencies, list):
            raise ValueError("dependencies must be an array of task IDs.")
        payload["dependencies"] = [parse_object_id(item, "dependency") for item in dependencies]
        if payload["dependencies"]:
            found = db.tasks.count_documents({"_id": {"$in": payload["dependencies"]}})
            if found != len(set(payload["dependencies"])):
                raise ValueError("One or more dependencies do not exist.")
    elif not partial:
        payload["dependencies"] = []
    if "can_run_parallel" in payload:
        value = payload["can_run_parallel"]
        payload["can_run_parallel"] = value if isinstance(value, bool) else str(value).lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
    elif not partial:
        payload["can_run_parallel"] = False
    return payload


def get_task_or_404(task_id):
    try:
        task = db.tasks.find_one({"_id": parse_object_id(task_id, "task_id")})
    except ValueError:
        abort(404)
    if task is None:
        abort(404)
    return task


@app.errorhandler(ValueError)
def handle_value_error(error):
    if request.path.startswith("/api/"):
        return jsonify({"error": str(error)}), 400
    flash(str(error), "error")
    return redirect(request.referrer or url_for("dashboard"))


@app.get("/")
def dashboard():
    summary = {
        "users": db.users.count_documents({}),
        "projects": db.projects.count_documents({}),
        "tasks": db.tasks.count_documents({}),
        "statuses": {
            status: db.tasks.count_documents({"status": status}) for status in VALID_STATUSES
        },
    }
    return render_template("dashboard.html", summary=summary)


@app.get("/users")
def users_page():
    return render_template("users.html", users=list(db.users.find().sort("name", 1)))


@app.get("/projects")
def projects_page():
    projects = list(db.projects.find().sort("name", 1))
    for project in projects:
        project["task_count"] = db.tasks.count_documents({"project_id": project["_id"]})
    return render_template("projects.html", projects=projects)


@app.get("/projects/<project_id>/tasks")
def project_tasks_page(project_id):
    project_oid = parse_object_id(project_id, "project_id")
    project = db.projects.find_one({"_id": project_oid})
    if project is None:
        abort(404)
    status = request.args.get("status")
    query = {"project_id": project_oid}
    if status in VALID_STATUSES:
        query["status"] = status
    tasks = list(db.tasks.find(query).sort("created_at", 1))
    users = {user["_id"]: user for user in db.users.find()}
    return render_template(
        "tasks.html", project=project, tasks=tasks, users=users, statuses=VALID_STATUSES
    )


@app.get("/tasks/<task_id>")
def task_detail_page(task_id):
    task = get_task_or_404(task_id)
    project = db.projects.find_one({"_id": task["project_id"]})
    assigned_user = db.users.find_one({"_id": task["assigned_user_id"]})
    dependencies = list(db.tasks.find({"_id": {"$in": task.get("dependencies", [])}}))
    return render_template(
        "task_detail.html",
        task=task,
        project=project,
        assigned_user=assigned_user,
        dependencies=dependencies,
        users=list(db.users.find().sort("name", 1)),
        statuses=VALID_STATUSES,
    )


@app.route("/tasks/new", methods=["GET", "POST"])
def create_task_page():
    if request.method == "POST":
        payload = task_payload(request.form)
        now = datetime.now(timezone.utc)
        payload.update(created_at=now, updated_at=now)
        task_id = db.tasks.insert_one(payload).inserted_id
        flash("Task created.", "success")
        return redirect(url_for("task_detail_page", task_id=task_id))
    return render_template(
        "task_form.html",
        projects=list(db.projects.find().sort("name", 1)),
        users=list(db.users.find().sort("name", 1)),
        statuses=VALID_STATUSES,
        selected_project=request.args.get("project_id", ""),
    )


@app.post("/tasks/<task_id>/update")
def update_task_page(task_id):
    get_task_or_404(task_id)
    payload = task_payload(request.form, partial=True)
    payload["updated_at"] = datetime.now(timezone.utc)
    db.tasks.update_one({"_id": parse_object_id(task_id)}, {"$set": payload})
    flash("Task updated.", "success")
    return redirect(url_for("task_detail_page", task_id=task_id))


@app.get("/api/users")
def api_users():
    return jsonify(serialize(list(db.users.find().sort("name", 1))))


@app.get("/api/projects")
def api_projects():
    return jsonify(serialize(list(db.projects.find().sort("name", 1))))


@app.get("/api/projects/<project_id>/tasks")
def api_project_tasks(project_id):
    project_oid = parse_object_id(project_id, "project_id")
    if not db.projects.find_one({"_id": project_oid}):
        return jsonify({"error": "Project not found."}), 404
    return jsonify(serialize(list(db.tasks.find({"project_id": project_oid}))))


@app.get("/api/tasks/<task_id>")
def api_task(task_id):
    return jsonify(serialize(get_task_or_404(task_id)))


@app.post("/api/tasks")
def api_create_task():
    payload = task_payload(request.get_json(silent=True) or {})
    now = datetime.now(timezone.utc)
    payload.update(created_at=now, updated_at=now)
    task_id = db.tasks.insert_one(payload).inserted_id
    return jsonify(serialize(db.tasks.find_one({"_id": task_id}))), 201


@app.patch("/api/tasks/<task_id>")
def api_update_task(task_id):
    task = get_task_or_404(task_id)
    payload = task_payload(request.get_json(silent=True) or {}, partial=True)
    if not payload:
        return jsonify({"error": "No supported fields supplied."}), 400
    if task["_id"] in payload.get("dependencies", []):
        return jsonify({"error": "A task cannot depend on itself."}), 400
    payload["updated_at"] = datetime.now(timezone.utc)
    db.tasks.update_one({"_id": task["_id"]}, {"$set": payload})
    return jsonify(serialize(db.tasks.find_one({"_id": task["_id"]})))


@app.get("/health")
def health():
    mongo_client.admin.command("ping")
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(
        host=PARAMETERS["FlaskHost"],
        port=int(PARAMETERS["FlaskPort"]),
        debug=False,
    )
