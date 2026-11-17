# effen

This is an Neovim Plugin I'd like you to make to manage functions. It should support C and C++ for now, but plan for future language support.
Assume I have a working LSP.
The general workflow I'd like is to

1. Write a undeclared funciton call direct into my code with arguments and optionally an assignment for the return variable.
2. put my cursor over the function and invoke the plugin.
3. All prompts shall be a floating text box like rename

The plugin will:

1. deduce the function prototype from the arguments passed into it and the assignment operator if available.
2. Optionally create the function declaration in the header file if specified.
3. Create a function definition template in the current file, or in another file if specified - prompt with a floating text box like rename
4. Open the function definition in another buffer or a split view for modification
5. Update the function declaration if the definition is modified.

some keybindings id like are (where "[]" denotes that something is an option and should not yet invoke the plugin, * denotes default):

<Leader-f> 
n (new) - places global marker on current line before jumping to the newly created definition
    [m] - prompt for modifiers to function signature
    [|/_/f] - open definition in vertical/horizontal/floating view for editing
    [h] - put declaration in header file, default to header file with same name as current source file, prompt though
    [l] - means no jump to definition, i'll fill it in later.
    a - append definition to end of current file. place marker and jump to new definiton
    n - create a new source file and put definition in there - prompt for source file name

r (return to marker set by new, then remove marker)

u (update) - only valid when in definition, this should update the declaration/prototype. otherwise do nothing
