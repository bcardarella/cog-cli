const { tokenize } = require('./tokenizer');
const { Parser } = require('./parser');
const { evaluate } = require('./evaluator');

function calc(expression) {
  const tokens = tokenize(expression);
  const parser = new Parser(tokens);
  const ast = parser.parse();
  return evaluate(ast);
}

const expr = '2^3^2';
const result = calc(expr);
console.log(`${expr} = ${result}`);
