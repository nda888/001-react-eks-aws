import React from "react";
import axios from "axios";
import "./App.scss";
import AddTodo from "./components/AddTodo";
import TodoList from "./components/TodoList";

export default class App extends React.Component {
  constructor(props) {
    super(props);

    this.state = {
      todos: [],
    };
  }

  componentDidMount() {
    axios.defaults.headers.common["Authorization"] = `Bearer ${import.meta.env.VITE_API_TOKEN}`;
    axios.get("/api")
      .then((response) => {
        this.setState({ todos: response.data.data });
      })
      .catch((e) => console.log("Error : ", e));
  }

  handleAddTodo = (value) => {
    axios
      .post("/api/todos", { text: value })
      .then((response) => {
        this.setState({
          todos: [...this.state.todos, response.data.data],
        });
      })
      .catch((e) => console.log("Error : ", e));
  };

  handleRemoveTodo = (id) => {
    axios
      .delete(`/api/todos/${id}`)
      .then(() => {
        this.setState({
          todos: this.state.todos.filter((t) => t._id !== id),
        });
      })
      .catch((e) => console.log("Error : ", e));
  };

  render() {
    return (
      <div className="App container">
        <div className="container-fluid">
          <div className="row">
            <div className="col-12">
              <h1>Noting</h1>
              <div className="todo-app">
                <AddTodo handleAddTodo={this.handleAddTodo} />
                <TodoList todos={this.state.todos} handleRemoveTodo={this.handleRemoveTodo} />
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  }
}
