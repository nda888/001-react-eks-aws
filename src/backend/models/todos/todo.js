/**
 * Created by Syed Afzal
 */
const mongoose = require("mongoose");

const Todo = mongoose.model("Todo", {
  text: {
    type: String,
    trim: true,
    required: true,
    maxlength: 200,
  },
  ownerId: {
    type: String,
    default: "shared",
    required: true,
  },
});

module.exports = { Todo };
