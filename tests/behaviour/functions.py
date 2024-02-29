def a():
    print(1)

def b():
    c()

def c():
    print(2)

a()
b()