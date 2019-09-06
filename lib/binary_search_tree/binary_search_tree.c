/*
 * Copyright (c) 2019 LK Trusty Authors. All Rights Reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <lib/binary_search_tree.h>

/**
 * bst_is_right_child - Internal helper function
 * @node:   Node to check.
 *
 * Return: %true if @node is the right child of @node->parent. %false if
 *         @node->parent is %NULL or if @node is the left child of
 *         @node->parent.
 */
static bool bst_is_right_child(struct bst_node *node) {
    DEBUG_ASSERT(node);
    DEBUG_ASSERT(!node->parent || node->parent->child[0] == node ||
                 node->parent->child[1] == node);
    return node->parent && node->parent->child[1] == node;
}

/**
 * bst_parent_ptr - Internal helper function
 * @root:   Tree.
 * @node:   Node in @root.
 *
 * Return: Pointer where @node is linked in the tree. If @node is the root node
 * this is &root->root, otherwise it is the address of child pointer in the
 * parent node of @node that points to @node.
 */
static struct bst_node **bst_parent_ptr(struct bst_root *root,
                                        struct bst_node *node) {
    DEBUG_ASSERT(root);
    DEBUG_ASSERT(node);
    struct bst_node **parent_ptr = node->parent ?
        &node->parent->child[bst_is_right_child(node)] : &root->root;
    DEBUG_ASSERT(*parent_ptr == node);
    return parent_ptr;
}

/**
 * bst_link_node - Internal helper function
 * @parent:         Target node.
 * @is_right_child: Index of child to set.
 * @child:          New child node.
 *
 * Set child node in @parent. If @child is not %NULL, update it to point to
 * @parent.
 */
static void bst_link_node(struct bst_node *parent,
                          bool is_right_child,
                          struct bst_node *child) {
    parent->child[is_right_child] = child;
    if (child) {
        child->parent = parent;
    }
}

/**
 * bst_move_node - Internal helper function
 * @root:       Tree.
 * @old_node:   Node to unlink.
 * @new_node:   Node to link where @old_node was.
 *
 * Replace node in @root at @old_node with @new_node.
 */
static void bst_move_node(struct bst_root *root,
                          struct bst_node *old_node,
                          struct bst_node *new_node) {
    DEBUG_ASSERT(root);
    DEBUG_ASSERT(old_node);

    *bst_parent_ptr(root, old_node) = new_node;
    if (new_node) {
        new_node->parent = old_node->parent;
    }
    old_node->parent = NULL;
}

/**
 * bst_find_edge - Internal helper function
 * @node:   Node to start search at.
 * @edge:   Direction if search.
 *
 * Return: leftmost (if @edge is %false) or rightmost (if @edge is %true) node
 * in subtree with @node as root.
 */
static struct bst_node *bst_find_edge(struct bst_node *node, bool edge) {
    struct bst_node *saved_node;

    DEBUG_ASSERT(node);

    do {
        saved_node = node;
        node = node->child[edge];
    } while (node);

    return saved_node;
}

/**
 * bst_delete_all_helper - Internal helper function
 * @root:   Tree.
 * @node:   Node to delete (most be the leftmost node in @root).
 *
 * Helper function to delete leftmost node in @root, assuming all other nodes
 * will be deleted next.
 */
void bst_delete_all_helper(struct bst_root *root, struct bst_node *node) {
    DEBUG_ASSERT(root);
    DEBUG_ASSERT(node);
    DEBUG_ASSERT(!node->child[0]);
    bst_move_node(root, node, node->child[1]);
}

void bst_delete(struct bst_root *root, struct bst_node *node) {
    DEBUG_ASSERT(root);
    DEBUG_ASSERT(node);

    struct bst_node *new_child;
    bool node_is_right_child = bst_is_right_child(node);
    if (!node->child[0]) {
        /*
         * If @node has no left child, link its right child in its place. (The
         * right child could be %NULL in this case)
         */
        new_child = node->child[1];
    } else if (!node->child[1]) {
        /*
         * If @node has no right child, link its left child in its place.
         */
        DEBUG_ASSERT(node->child[0]);
        new_child = node->child[0];
    } else {
        /*
         * If @node has both left and right children, delete (from the tree
         * structure point of view) the left-most node in the right sub-tree or
         * the right-most node in the left sub-tree instead. Either side would
         * work.
         */
        struct bst_node *edge_node = bst_find_edge(
                node->child[!node_is_right_child], node_is_right_child);
        struct bst_node *edge_child = edge_node->child[!node_is_right_child];
        bst_move_node(root, edge_node, edge_child);

        new_child = edge_node;
        DEBUG_ASSERT(new_child);
        bst_link_node(new_child, 0, node->child[0]);
        bst_link_node(new_child, 1, node->child[1]);
    }
    bst_move_node(root, node, new_child);
    node->rank = 0;
}

/**
 * bst_prev_next - Internal helper function
 * @root:       Tree.
 * @node:       Node to move from.
 * @dir_next:   Directon to move.
 *
 * Return: If @node is %NULL and @dir_next is %false, right-most node in @root.
 *         If @node is %NULL and @dir_next is %true, left-most node in @root.
 *         If @node is not %NULL and @dir_next is %false, right-most node to the
 *         left of @node.
 *         If @node is not %NULL and @dir_next is %true, left-most node to the
 *         right of @node.
 *         %NULL if the node described above does not exist.
 */
static struct bst_node *bst_prev_next(const struct bst_root *root,
                                      struct bst_node *node,
                                      bool dir_next) {
    DEBUG_ASSERT(root);

    struct bst_node *next_child = node ? node->child[dir_next] : root->root;

    if (!node && !next_child) {
        return NULL; /* Empty tree */
    }

    /*
     * Comments below assume @dir_next is %true. For the @dir_next is %false
     * case, swap left and right.
     */
    if (next_child) {
        /* There is a right child, return the left-most node in that subtree */
        return bst_find_edge(next_child, !dir_next);
    } else {
        /* No right child, next node is the first right parent */
        struct bst_node *next_parent = node;
        while (bst_is_right_child(next_parent) == dir_next) {
            next_parent = next_parent->parent;
            if (!next_parent) {
                return NULL;
            }
        }
        return next_parent->parent;
    }
}

struct bst_node *bst_prev(struct bst_root *root, struct bst_node *node) {
    return bst_prev_next(root, node, false);
}

struct bst_node *bst_next(const struct bst_root *root, struct bst_node *node) {
    return bst_prev_next(root, node, true);
}
