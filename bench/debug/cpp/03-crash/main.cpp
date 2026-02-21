#include "ast.h"
#include "lexer.h"
#include "parser.h"
#include <iostream>
#include <string>

// Defined in evaluator.cpp
double evaluate(ASTNode* node);

void evalAndPrint(const std::string& expr) {
    try {
        Lexer lexer(expr);
        auto tokens = lexer.tokenize();
        Parser parser(tokens);
        ASTNode* ast = parser.parse();
        double result = evaluate(ast);
        std::cout << expr << " = " << result << std::endl;
        delete ast;
    } catch (const std::exception& e) {
        std::cout << expr << " => ERROR: " << e.what() << std::endl;
    }
}

int main() {
    // These expressions work fine (no unary minus before multiplication)
    evalAndPrint("3 + 4");
    evalAndPrint("(3 + 4) * 2");
    evalAndPrint("10 / (2 + 3)");

    evalAndPrint("-(3 + 4) * 2");

    return 0;
}
