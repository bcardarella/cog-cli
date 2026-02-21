#include "bst.h"
#include <iostream>

int main() {
    BST tree;

    // Build a BST:
    //          10
    //         /  \
    //        5    15
    //       / \   / \
    //      2   8 12  20
    //             \
    //             13
    tree.insert(10);
    tree.insert(5);
    tree.insert(15);
    tree.insert(2);
    tree.insert(8);
    tree.insert(12);
    tree.insert(20);
    tree.insert(13);

    // Delete root node 10 (two children case).
    tree.remove(10);

    // Print in-order traversal
    auto result = tree.inorder();
    std::cout << "Traversal:";
    for (int val : result) {
        std::cout << " " << val;
    }
    std::cout << std::endl;

    return 0;
}
