import React from "react";

export default class TodoList extends React.Component {
  constructor(props) {
    super(props);

    this.state = {
      activeIndex: 0,
    };
  }

  handleActive(index) {
    this.setState({
      activeIndex: index,
    });
  }

  renderTodos(todos) {
    return (
      <ul className="list-group todo-list">
        {todos.map((todo, i) => (
          <li
            className="list-group-item todo-item"
            key={todo._id}
            onClick={() => {
              this.handleActive(i);
            }}
          >
            <div className={"todo-content cursor-pointer " + (i === this.state.activeIndex ? "active" : "")}>
              <span>{todo.text}</span>
            </div>
            <div className="todo-action">
              <button
                className="btn btn-orange"
                onClick={(e) => {
                  e.stopPropagation();
                  this.props.handleRemoveTodo(todo._id);
                }}
              >
                Remove
              </button>
            </div>
          </li>
        ))}
      </ul>
    );
  }

  render() {
    let { todos } = this.props;
    return todos.length > 0 ? (
      this.renderTodos(todos)
    ) : (
      <div className="alert alert-primary" role="alert">
        No Todos to display
      </div>
    );
  }
}
