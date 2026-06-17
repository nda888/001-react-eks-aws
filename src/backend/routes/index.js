const express = require("express");
const mongoose = require("mongoose");
const rateLimit = require("express-rate-limit");
const serverResponses = require("../utils/helpers/responses");
const messages = require("../config/messages");
const { Todo } = require("../models/todos/todo");

const TODO_TEXT_MAX_LENGTH = 200;

const parseTodoText = (value) => {
  if (typeof value !== "string") {
    return null;
  }

  const text = value.trim();
  if (!text || text.length > TODO_TEXT_MAX_LENGTH) {
    return null;
  }

  return text;
};

const rateLimitMessage = "Too many requests. Please try again later.";

const createRateLimiter = (windowMs, max) =>
  rateLimit({
    windowMs,
    limit: max,
    standardHeaders: true,
    legacyHeaders: false,
    message: { message: rateLimitMessage },
  });

const routes = (app) => {
  const router = express.Router();
  const listTodosLimiter = createRateLimiter(60 * 1000, 60);
  const createTodoLimiter = createRateLimiter(60 * 1000, 20);
  const deleteTodoLimiter = createRateLimiter(60 * 1000, 30);

  router.post("/todos", createTodoLimiter, (req, res) => {
    const text = parseTodoText(req.body.text);
    if (!text) {
      return serverResponses.sendError(res, messages.BAD_REQUEST);
    }

    const todo = new Todo({
      text,
    });

    todo
      .save()
      .then((result) => {
        serverResponses.sendSuccess(res, messages.SUCCESSFUL, result);
      })
      .catch((e) => {
        console.error("Failed to create todo", e);
        serverResponses.sendError(res, messages.BAD_REQUEST);
      });
  });

  router.get("/", listTodosLimiter, (req, res) => {
    Todo.find({}, { __v: 0 })
      .then((todos) => {
        serverResponses.sendSuccess(res, messages.SUCCESSFUL, todos);
      })
      .catch((e) => {
        console.error("Failed to list todos", e);
        serverResponses.sendError(res, messages.BAD_REQUEST);
      });
  });

  router.delete("/todos/:id", deleteTodoLimiter, (req, res) => {
    if (!mongoose.isValidObjectId(req.params.id)) {
      return serverResponses.sendError(res, messages.BAD_REQUEST);
    }

    Todo.findByIdAndDelete(req.params.id)
      .then(() => {
        serverResponses.sendSuccess(res, messages.SUCCESSFUL_DELETE);
      })
      .catch((e) => {
        console.error("Failed to delete todo", e);
        serverResponses.sendError(res, messages.BAD_REQUEST);
      });
  });

  //it's a prefix before api it is useful when you have many modules and you want to
  //differentiate b/w each module you can use this technique
  app.use("/api", router);
};
module.exports = routes;
