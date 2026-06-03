/**
 * Created by Syed Afzal
 */
require("./config/config");

const express = require("express");
const path = require("path");
const cookieParser = require("cookie-parser");
const bodyParser = require("body-parser");
const cors = require("cors");
const db = require("./db");

const app = express();

//connection from db here
db.connect(app);

app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: false }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, "public")));

app.get("/healthz", (req, res) => {
  res.status(200).json({ status: "ok" });
});

//  adding routes
require("./routes")(app);

app.on("ready", () => {
  const port = process.env.PORT || 3000;

  app.listen(port, () => {
    console.log("Server is up on port", port);
  });
});

module.exports = app;
